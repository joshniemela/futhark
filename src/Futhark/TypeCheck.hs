{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, TypeFamilies #-}
-- | The type checker checks whether the program is type-consistent.
module Futhark.TypeCheck
  ( -- * Interface
    checkProg
  , checkProgNoUniqueness
  , TypeError (..)
  , ErrorCase (..)

    -- * Extensionality
  , TypeM
  , bad
  , context
  , message
  , Checkable (..)
  , lookupVar
  , lookupAliases
  , Occurences
  , UsageMap
  , usageMap
  , collectOccurences

    -- * Checkers
  , require
  , requireI
  , checkSubExp
  , checkExp
  , checkType
  , checkExtType
  , matchExtPattern
  , matchExtReturnType
  , argType
  , checkArg
  , checkSOACArrayArgs
  , checkLambda
  , checkExtLambda
  , checkFun'
  , checkLambdaParams
  , checkBody
  , consumeOnlyParams
  )
  where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad.RWS
import Data.List
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Maybe

import Prelude

import qualified Futhark.Representation.AST as AST
import Futhark.Representation.Aliases
import Futhark.Analysis.Alias
import Futhark.Util.Pretty (Pretty, prettyDoc, indent, ppr, text, (<+>), align)

-- | Information about an error during type checking.  The 'Show'
-- instance for this type produces a human-readable description.
data ErrorCase lore =
    TypeError String
  -- ^ A general error happened for the given reason.
  | UnifyError (Exp lore) Type (Exp lore) Type
  -- ^ Types of two expressions failed to unify.
  | UnexpectedType (Exp lore) Type [Type]
  -- ^ Expression of type was not one of the expected
  -- types.
  | ReturnTypeError Name [ExtType] [ExtType]
  -- ^ The body of a function definition has a different
  -- type than its declaration.
  | DupDefinitionError Name
  -- ^ Two functions have been defined with the same name.
  | DupParamError Name VName
  -- ^ Two function parameters share the same name.
  | DupPatternError VName
  -- ^ Two pattern variables share the same name.
  | InvalidPatternError (Pattern lore) [ExtType] (Maybe String)
  -- ^ The pattern is not compatible with the type or is otherwise
  -- inconsistent.
  | UnknownVariableError VName
  -- ^ Unknown variable of the given name referenced.
  | UnknownFunctionError Name
  -- ^ Unknown function of the given name called.
  | ParameterMismatch (Maybe Name) [Type] [Type]
  -- ^ A function (possibly anonymous) was called with invalid
  -- arguments.  The second argument is the specific types of
  -- parameters accepted.
  | UseAfterConsume VName
  -- ^ A variable was attempted used after being
  -- consumed.  The last location is the point of
  -- consumption.
  | IndexingError Int Int
  -- ^ Too many indices provided.  The first integer is
  -- the number of dimensions in the array being
  -- indexed.
  | BadAnnotation String Type Type
  -- ^ One of the type annotations fails to match with the
  -- derived type.  The string is a description of the
  -- role of the type.  The last type is the new derivation.
  | ReturnAliased Name VName
  -- ^ The unique return value of the function aliases
  -- one of the function parameters.
  | UniqueReturnAliased Name
  -- ^ A unique element of the tuple returned by the
  -- function aliases some other element of the tuple.
  | NotAnArray VName Type
  -- ^ The given variable is not array-typed.
  | PermutationError [Int] Int (Maybe VName)
  -- ^ The permutation is not valid.

instance Checkable lore => Show (ErrorCase lore) where
  show (TypeError msg) =
    "Type error:\n" ++ msg
  show (UnifyError e1 t1 e2 t2) =
    "Cannot unify type " ++ pretty t1 ++
    " of expression\n" ++ prettyDoc 160 (indent 2 $ ppr e1) ++
    "\nwith type " ++ pretty t2 ++
    " of expression\n" ++ prettyDoc 160 (indent 2 $ ppr e2)
  show (UnexpectedType e _ []) =
    "Type of expression\n" ++
    prettyDoc 160 (indent 2 $ ppr e) ++
    "\ncannot have any type - possibly a bug in the type checker."
  show (UnexpectedType e t ts) =
    "Type of expression\n" ++
    prettyDoc 160 (indent 2 $ ppr e) ++
    "\nmust be one of " ++ intercalate ", " (map pretty ts) ++ ", but is " ++
    pretty t ++ "."
  show (ReturnTypeError fname rettype bodytype) =
    "Declaration of function " ++ nameToString fname ++
    " declares return type\n  " ++ prettyTuple rettype ++
    "\nBut body has type\n  " ++ prettyTuple bodytype
  show (DupDefinitionError name) =
    "Duplicate definition of function " ++ nameToString name ++ ""
  show (DupParamError funname paramname) =
    "Parameter " ++ textual paramname ++
    " mentioned multiple times in argument list of function " ++
    nameToString funname ++ "."
  show (DupPatternError name) =
    "Variable " ++ textual name ++ " bound twice in pattern."
  show (InvalidPatternError pat t desc) =
    "Pattern " ++ pretty pat ++
    " cannot match value of type " ++ pretty t ++ end
    where end = case desc of Nothing -> "."
                             Just desc' -> ":\n" ++ desc'
  show (UnknownVariableError name) =
    "Use of unknown variable " ++ textual name ++ "."
  show (UnknownFunctionError fname) =
    "Call of unknown function " ++ nameToString fname ++ "."
  show (ParameterMismatch fname expected got) =
    "In call of " ++ fname' ++ ":\n" ++
    "expecting " ++ show nexpected ++ " argument(s) of type(s) " ++
     expected' ++ ", but got " ++ show ngot ++
    " arguments of types " ++ intercalate ", " (map pretty got) ++ "."
    where (nexpected, expected') =
            (length expected, intercalate ", " $ map pretty expected)
          ngot = length got
          fname' = maybe "anonymous function" (("function "++) . nameToString) fname
  show (UseAfterConsume name) =
    "Variable " ++ textual name ++ " used" ++
    ", but it was previously consumed.  (Possibly through aliasing.)"
  show (IndexingError dims got) =
    show got ++ " indices given, but type of indexee has " ++ show dims ++ " dimension(s)."
  show (BadAnnotation desc expected got) =
    "Annotation of \"" ++ desc ++ "\" type of expression is " ++ pretty expected ++
    ", but derived to be " ++ pretty got ++ "."
  show (ReturnAliased fname name) =
    "Unique return value of function " ++ nameToString fname ++
    " is aliased to " ++ textual name ++ ", which is not consumed."
  show (UniqueReturnAliased fname) =
    "A unique tuple element of return value of function " ++
    nameToString fname ++ " is aliased to some other tuple component."
  show (NotAnArray e t) =
    "The expression " ++ pretty e ++
    " is expected to be an array, but is " ++ pretty t ++ "."
  show (PermutationError perm rank name) =
    "The permutation (" ++ intercalate ", " (map show perm) ++
    ") is not valid for array " ++ name' ++ "of rank " ++ show rank ++ "."
    where name' = maybe "" ((++" ") . textual) name

-- | A type error.
data TypeError lore = Error [String] (ErrorCase lore)

instance Checkable lore => Show (TypeError lore) where
  show (Error [] err) =
    show err
  show (Error msgs err) =
    intercalate "\n" msgs ++ "\n" ++ show err

-- | A tuple of a return type and a list of parameters, possibly
-- named.
type FunBinding lore = (RetType lore, [FParam lore])

data VarBinding lore = Bound (NameInfo (Aliases lore))

data Usage = Consumed
           | Observed
             deriving (Eq, Ord, Show)

data Occurence = Occurence { observed :: Names
                           , consumed :: Names
                           }
             deriving (Eq, Show)

observation :: Names -> Occurence
observation = flip Occurence HS.empty

consumption :: Names -> Occurence
consumption = Occurence HS.empty

nullOccurence :: Occurence -> Bool
nullOccurence occ = HS.null (observed occ) && HS.null (consumed occ)

type Occurences = [Occurence]

type UsageMap = HM.HashMap VName [Usage]

usageMap :: Occurences -> UsageMap
usageMap = foldl comb HM.empty
  where comb m (Occurence obs cons) =
          let m' = HS.foldl' (ins Observed) m obs
          in HS.foldl' (ins Consumed) m' cons
        ins v m k = HM.insertWith (++) k [v] m

allConsumed :: Occurences -> Names
allConsumed = HS.unions . map consumed

seqOccurences :: Occurences -> Occurences -> Occurences
seqOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt occurs1 ++ occurs2
  where filt occ =
          occ { observed = observed occ `HS.difference` postcons }
        postcons = allConsumed occurs2

altOccurences :: Occurences -> Occurences -> Occurences
altOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt occurs1 ++ occurs2
  where filt occ =
          occ { consumed = consumed occ `HS.difference` postcons
              , observed = observed occ `HS.difference` postcons }
        postcons = allConsumed occurs2

unOccur :: Names -> Occurences -> Occurences
unOccur to_be_removed = filter (not . nullOccurence) . map unOccur'
  where unOccur' occ =
          occ { observed = observed occ `HS.difference` to_be_removed
              , consumed = consumed occ `HS.difference` to_be_removed
              }

-- | The 'Consumption' data structure is used to keep track of which
-- variables have been consumed, as well as whether a violation has been detected.
data Consumption = ConsumptionError String
                 | Consumption Occurences
                 deriving (Show)

instance Monoid Consumption where
  mempty = Consumption mempty
  ConsumptionError e `mappend` _ = ConsumptionError e
  _ `mappend` ConsumptionError e = ConsumptionError e
  Consumption o1 `mappend` Consumption o2
    | v:_ <- HS.toList $ consumed_in_o1 `HS.intersection` used_in_o2 =
        ConsumptionError $ "Variable " <> pretty v <> " referenced after being consumed."
    | otherwise =
        Consumption $ o1 `seqOccurences` o2
    where consumed_in_o1 = mconcat $ map consumed o1
          used_in_o2 = mconcat $ map consumed o2 <> map observed o2

-- | The environment contains a variable table and a function table.
-- Type checking happens with access to this environment.  The
-- function table is only initialised at the very beginning, but the
-- variable table will be extended during type-checking when
-- let-expressions are encountered.
data Env lore =
  Env { envVtable :: HM.HashMap VName (VarBinding lore)
      , envFtable :: HM.HashMap Name (FunBinding lore)
      , envCheckOccurences :: Bool
      , envContext :: [String]
      }

-- | The type checker runs in this monad.
newtype TypeM lore a = TypeM (RWST
                              (Env lore)     -- Reader
                              Consumption        -- Writer
                              ()                 -- State
                              (Either (TypeError lore)) -- Inner monad
                              a)
  deriving (Monad, Functor, Applicative,
            MonadReader (Env lore),
            MonadWriter Consumption)

instance Checkable lore =>
         HasScope (Aliases lore) (TypeM lore) where
  lookupType = fmap typeOf . lookupVar
  askScope = asks $ HM.fromList . mapMaybe varType . HM.toList . envVtable
    where varType (name, Bound attr) = Just (name, attr)

runTypeM :: Env lore -> TypeM lore a
         -> Either (TypeError lore) a
runTypeM env (TypeM m) = fst <$> evalRWST m env ()

bad :: ErrorCase lore -> TypeM lore a
bad e = do
  messages <- asks envContext
  TypeM $ lift $ Left $ Error (reverse messages) e

-- | Add information about what is being type-checked to the current
-- context.  Liberal use of this combinator makes it easier to track
-- type errors, as the strings are added to type errors signalled via
-- 'bad'.
context :: String
          -> TypeM lore a
          -> TypeM lore a
context s = local $ \env -> env { envContext = s : envContext env}

message :: Pretty a =>
           String -> a -> String
message s x = prettyDoc 80 $
              text s <+> align (ppr x)

liftEitherS :: Either String a -> TypeM lore a
liftEitherS = either (bad . TypeError) return

occur :: Occurences -> TypeM lore ()
occur = tell . Consumption

-- | Proclaim that we have made read-only use of the given variable.
-- No-op unless the variable is array-typed.
observe :: Checkable lore =>
           VName -> TypeM lore ()
observe name = do
  attr <- lookupVar name
  unless (primType $ typeOf attr) $
    occur [observation $ aliases attr]

-- | Proclaim that we have written to the given variable.
consume :: Names -> TypeM lore ()
consume als = occur [consumption als]

collectOccurences :: TypeM lore a -> TypeM lore (a, Occurences)
collectOccurences m = pass $ do
  (x, c) <- listen m
  o <- maybeCheckConsumption c
  return ((x, o), const mempty)

noDataflow :: TypeM lore a -> TypeM lore a
noDataflow = censor $ const mempty

maybeCheckConsumption :: Consumption -> TypeM lore Occurences
maybeCheckConsumption (ConsumptionError e) = do
  check <- asks envCheckOccurences
  if check
    then bad $ TypeError e
    else return mempty
maybeCheckConsumption (Consumption os) =
  return os

alternative :: TypeM lore a -> TypeM lore b -> TypeM lore (a,b)
alternative m1 m2 = pass $ do
  (x, c1) <- listen m1
  (y, c2) <- listen m2
  os1 <- maybeCheckConsumption c1
  os2 <- maybeCheckConsumption c2
  let usage = Consumption $ os1 `altOccurences` os2
  return ((x, y), const usage)

-- | Permit consumption of only the specified names.  If one of these
-- names is consumed, the consumption will be rewritten to be a
-- consumption of the corresponding alias set.  Consumption of
-- anything else will result in a type error.
consumeOnlyParams :: [(VName, Names)] -> TypeM lore a -> TypeM lore a
consumeOnlyParams consumable m = do
  (x, os) <- collectOccurences m
  tell . Consumption =<< mapM inspect os
  return x
  where inspect o = do
          new_consumed <- mconcat <$> mapM wasConsumed (HS.toList $ consumed o)
          return o { consumed = new_consumed }
        wasConsumed v
          | Just als <- lookup v consumable = return als
          | otherwise =
            bad $ TypeError $
            unlines [pretty v ++ " was invalidly consumed.",
                     what ++ " can be consumed here."]
        what | null consumable = "Nothing"
             | otherwise = "Only " ++ intercalate ", " (map (pretty . fst) consumable)

-- | Given the immediate aliases, compute the full transitive alias
-- set (including the immediate aliases).
expandAliases :: Names -> Env lore -> Names
expandAliases names env = names `HS.union` aliasesOfAliases
  where aliasesOfAliases =  mconcat . map look . HS.toList $ names
        look k = case HM.lookup k $ envVtable env of
          Just (Bound (LetInfo (als, _))) -> unNames als
          _                               -> mempty

binding :: Checkable lore =>
           Scope (Aliases lore)
        -> TypeM lore a
        -> TypeM lore a
binding bnds = check . local (`bindVars` bnds)
  where bindVars = HM.foldlWithKey' bindVar
        boundnames = HM.keys bnds
        boundnameset = HS.fromList boundnames

        bindVar env name (LetInfo (Names' als, attr)) =
          let als' = expandAliases als env
              inedges = HS.toList als'
              update (Bound (LetInfo (Names' thesenames, thisattr))) =
                Bound $ LetInfo (Names' $ HS.insert name thesenames, thisattr)
              update b = b
          in env { envVtable =
                      HM.insert name (Bound $ LetInfo (Names' als', attr)) $
                      adjustSeveral update inedges $
                      envVtable env
                 }
        bindVar env name attr =
          env { envVtable = HM.insert name (Bound attr) $ envVtable env }

        adjustSeveral f = flip $ foldl $ flip $ HM.adjust f

        -- Check whether the bound variables have been used correctly
        -- within their scope.
        check m = do
          already_bound <- asks envVtable
          case filter (`HM.member` already_bound) $ HM.keys bnds of
            []  -> return ()
            v:_ -> bad $ TypeError $
                   "Variable " ++ pretty v ++ " being redefined."
          (a, os) <- collectOccurences m
          tell $ Consumption $ unOccur boundnameset os
          return a

lookupVar :: VName -> TypeM lore (NameInfo (Aliases lore))
lookupVar name = do
  bnd <- asks $ HM.lookup name . envVtable
  case bnd of
    Nothing -> bad $ UnknownVariableError name
    Just (Bound attr) -> return attr

lookupAliases :: VName -> TypeM lore Names
lookupAliases name = do
  als <- aliases <$> lookupVar name
  return $ HS.insert name als

aliases :: NameInfo (Aliases lore) -> Names
aliases (LetInfo (als, _)) = unNames als
aliases _ = mempty

subExpAliasesM :: SubExp -> TypeM lore Names
subExpAliasesM Constant{} = return mempty
subExpAliasesM (Var v)    = lookupAliases v

lookupFun :: Checkable lore =>
             Name
          -> [SubExp]
          -> TypeM lore (RetType lore, [DeclType])
lookupFun fname args = do
  bnd <- asks $ HM.lookup fname . envFtable
  case bnd of
    Nothing -> bad $ UnknownFunctionError fname
    Just (ftype, params) -> do
      argts <- mapM subExpType args
      case applyRetType ftype params $
           zip args argts of
        Nothing ->
          bad $ ParameterMismatch (Just fname)
          (map paramType params) argts
        Just rt ->
          return (rt, map paramDeclType params)

-- | Determine if the types of two subexpressions are identical.
-- Causes a 'TypeError vn' if they fail to match, and otherwise
-- returns their common type.
matchSubExpTypes :: Checkable lore =>
                    SubExp -> SubExp -> TypeM lore ()
matchSubExpTypes e1 e2 = do
  t1 <- subExpType e1
  t2 <- subExpType e2
  unless (t1 == t2) $
    bad $ UnifyError (PrimOp $ SubExp e1) t1
    (PrimOp $ SubExp e2) t2

-- | @checkAnnotation loc s t1 t2@ checks if @t2@ is equal to
-- @t1@.  If not, a 'BadAnnotation' is raised.
checkAnnotation :: String -> Type -> Type
                -> TypeM lore ()
checkAnnotation desc t1 t2
  | t2 == t1 = return ()
  | otherwise = bad $ BadAnnotation desc t1 t2

-- | @require ts se@ causes a '(TypeError vn)' if the type of @se@ is
-- not a subtype of one of the types in @ts@.
require :: Checkable lore => [Type] -> SubExp -> TypeM lore ()
require ts se = do
  t <- checkSubExp se
  unless (t `elem` ts) $
    bad $ UnexpectedType (PrimOp $ SubExp se) t ts

-- | Variant of 'require' working on variable names.
requireI :: Checkable lore => [Type] -> VName -> TypeM lore ()
requireI ts ident = require ts $ Var ident

checkArrIdent :: Checkable lore =>
                 VName -> TypeM lore Type
checkArrIdent v = do
  t <- lookupType v
  case t of
    Array{} -> return t
    _       -> bad $ NotAnArray v t

-- | Type check a program containing arbitrary type information,
-- yielding either a type error or a program with complete type
-- information.
checkProg :: Checkable lore =>
             AST.Prog lore -> Either (TypeError lore) ()
checkProg = checkProg' True

-- | As 'checkProg', but don't check whether uniqueness constraints
-- are being upheld.  The uniqueness of types must still be correct.
checkProgNoUniqueness :: Checkable lore =>
                         AST.Prog lore -> Either (TypeError lore) ()
checkProgNoUniqueness = checkProg' False

checkProg' :: Checkable lore =>
              Bool -> AST.Prog lore -> Either (TypeError lore) ()
checkProg' checkoccurs prog = do
  let typeenv = Env { envVtable = HM.empty
                    , envFtable = mempty
                    , envCheckOccurences = checkoccurs
                    , envContext = []
                    }

  runTypeM typeenv $ do
    ftable <- buildFtable
    local (\env -> env { envFtable = ftable }) $
      mapM_ (noDataflow . checkFun) $ progFunctions prog'
  where
    prog' = aliasAnalysis prog
    -- To build the ftable we loop through the list of function
    -- definitions.  In addition to the normal ftable information
    -- (name, return type, argument types), we also keep track of
    -- position information, in order to report both locations of
    -- duplicate function definitions.  The position information is
    -- removed at the end.
    buildFtable = do table <- initialFtable prog'
                     foldM expand table $ progFunctions prog'
    expand ftable (FunDef _ name ret params _)
      | HM.member name ftable =
        bad $ DupDefinitionError name
      | otherwise =
        return $ HM.insert name (ret,params) ftable

-- The prog argument is just to disambiguate the lore.
initialFtable :: Checkable lore =>
                 Prog lore -> TypeM lore (HM.HashMap Name (FunBinding lore))
initialFtable _ = fmap HM.fromList $ mapM addBuiltin $ HM.toList builtInFunctions
  where addBuiltin (fname, (t, ts)) = do
          ps <- mapM (primFParam name) ts
          return (fname, (primRetType t, ps))
        name = ID (nameFromString "x", 0)

checkFun :: Checkable lore =>
            FunDef lore -> TypeM lore ()
checkFun (FunDef _ fname rettype params body) =
  context ("In function " ++ nameToString fname) $
    checkFun' (fname,
               retTypeValues rettype,
               funParamsToNameInfos params,
               body) consumable $ do
      checkFunParams params
      checkRetType rettype
      checkFunBody fname rettype body
        where consumable = [ (paramName param, mempty)
                           | param <- params
                           , unique $ paramDeclType param
                           ]

funParamsToNameInfos :: Checkable lore =>
                        [FParam lore]
                     -> [(VName, NameInfo (Aliases lore))]
funParamsToNameInfos = map nameTypeAndLore
  where nameTypeAndLore fparam = (paramName fparam,
                                  FParamInfo $ paramAttr fparam)

checkFunParams :: Checkable lore =>
                  [FParam lore] -> TypeM lore ()
checkFunParams = mapM_ $ \param ->
  context ("In function parameter " ++ pretty param) $
    checkFParamLore (paramName param) (paramAttr param)

checkLambdaParams :: Checkable lore =>
                     [LParam lore] -> TypeM lore ()
checkLambdaParams = mapM_ $ \param ->
  context ("In lambda parameter " ++ pretty param) $
    checkLParamLore (paramName param) (paramAttr param)

checkFun' :: Checkable lore =>
             (Name,
              [DeclExtType],
              [(VName, NameInfo (Aliases lore))],
              BodyT (Aliases lore))
          -> [(VName, Names)]
          -> TypeM lore ()
          -> TypeM lore ()
checkFun' (fname, rettype, params, body) consumable check = do
  checkNoDuplicateParams
  binding (HM.fromList params) $
    consumeOnlyParams consumable $ do
      check
      checkReturnAlias $ bodyAliases body
  where param_names = map fst params

        checkNoDuplicateParams = foldM_ expand [] param_names

        expand seen pname
          | Just _ <- find (==pname) seen =
            bad $ DupParamError fname pname
          | otherwise =
            return $ pname : seen

        -- | Check that unique return values do not alias a
        -- non-consumed parameter.
        checkReturnAlias =
          foldM_ checkReturnAlias' HS.empty . returnAliasing rettype

        checkReturnAlias' seen (Unique, names)
          | any (`HS.member` HS.map snd seen) $ HS.toList names =
            bad $ UniqueReturnAliased fname
          | otherwise = do
            consume names
            return $ seen `HS.union` tag Unique names
        checkReturnAlias' seen (Nonunique, names)
          | any (`HS.member` seen) $ HS.toList $ tag Unique names =
            bad $ UniqueReturnAliased fname
          | otherwise = return $ seen `HS.union` tag Nonunique names

        tag u = HS.map $ \name -> (u, name)

        returnAliasing expected got =
          [ (uniqueness p, names) |
            (p,names) <- zip expected got ]

checkSubExp :: Checkable lore => SubExp -> TypeM lore Type
checkSubExp (Constant val) =
  return $ Prim $ primValueType val
checkSubExp (Var ident) = context ("In subexp " ++ pretty ident) $ do
  observe ident
  lookupType ident

checkBindings :: Checkable lore =>
                 [Binding lore] -> TypeM lore a
              -> TypeM lore a
checkBindings origbnds m = delve origbnds
  where delve (Let pat (_,annot) e:bnds) = do
          context ("In expression\n" ++ message "  " e) $
            checkExp e
          checkExpLore annot
          checkBinding pat e $
            delve bnds
        delve [] =
          m

checkResult :: Checkable lore =>
               Result -> TypeM lore ()
checkResult = mapM_ checkSubExp

checkFunBody :: Checkable lore =>
                Name
             -> RetType lore
             -> Body lore
             -> TypeM lore ()
checkFunBody fname rt (Body (_,lore) bnds res) = do
  checkBindings bnds $ do
    checkResult res
    matchReturnType fname rt res
  checkBodyLore lore

checkLambdaBody :: Checkable lore =>
                   [Type] -> Body lore -> TypeM lore ()
checkLambdaBody ret (Body (_,lore) bnds res) = do
  checkBindings bnds $ checkLambdaResult ret res
  checkBodyLore lore

checkLambdaResult :: Checkable lore =>
                     [Type] -> Result -> TypeM lore ()
checkLambdaResult ts es
  | length ts /= length es =
    bad $ TypeError $
    "Lambda has return type " ++ prettyTuple ts ++
    " describing " ++ show (length ts) ++ " values, but body returns " ++
    show (length es) ++ " values: " ++ prettyTuple es
  | otherwise = forM_ (zip ts es) $ \(t, e) -> do
      et <- checkSubExp e
      unless (et == t) $
        bad $ TypeError $
        "Subexpression " ++ pretty e ++ " has type " ++ pretty et ++
        " but expected " ++ pretty t

checkBody :: Checkable lore =>
             Body lore -> TypeM lore ()
checkBody (Body (_,lore) bnds res) = do
  checkBindings bnds $ checkResult res
  checkBodyLore lore

checkPrimOp :: Checkable lore =>
               PrimOp lore -> TypeM lore ()

checkPrimOp (SubExp es) =
  void $ checkSubExp es

checkPrimOp (ArrayLit [] _) =
  return ()

checkPrimOp (ArrayLit (e:es') t) = do
  let check elemt eleme = do
        elemet <- checkSubExp eleme
        unless (elemet == elemt) $
          bad $ TypeError $ pretty elemet ++
          " is not of expected type " ++ pretty elemt ++ "."
  et <- checkSubExp e

  -- Compare that type with the one given for the array literal.
  checkAnnotation "array-element" t et

  mapM_ (check et) es'

checkPrimOp (UnOp op e) = require [Prim $ unOpType op] e

checkPrimOp (BinOp op e1 e2) = checkBinOpArgs (binOpType op) e1 e2

checkPrimOp (CmpOp op e1 e2) = checkCmpOp op e1 e2

checkPrimOp (ConvOp op e) = require [Prim $ fst $ convTypes op] e

checkPrimOp (Index cs ident idxes) = do
  mapM_ (requireI [Prim Cert]) cs
  vt <- lookupType ident
  observe ident
  when (arrayRank vt < length idxes) $
    bad $ IndexingError (arrayRank vt) (length idxes)
  mapM_ (require [Prim int32]) idxes

checkPrimOp (Iota e x s) = do
  require [Prim int32] e
  require [Prim int32] x
  require [Prim int32] s

checkPrimOp (Replicate countexp valexp) = do
  require [Prim int32] countexp
  void $ checkSubExp valexp

checkPrimOp (Scratch _ shape) =
  mapM_ checkSubExp shape

checkPrimOp (Reshape cs newshape arrexp) = do
  rank <- arrayRank <$> checkArrIdent arrexp
  mapM_ (requireI [Prim Cert]) cs
  mapM_ (require [Prim int32] . newDim) newshape
  zipWithM_ (checkDimChange rank) newshape [0..]
  where checkDimChange _ (DimNew _) _ =
          return ()
        checkDimChange rank (DimCoercion se) i
          | i >= rank =
            bad $ TypeError $
            "Asked to coerce dimension " ++ show i ++ " to " ++ pretty se ++
            ", but array " ++ pretty arrexp ++ " has only " ++ pretty rank ++ " dimensions"
          | otherwise =
            return ()

checkPrimOp (Rearrange cs perm arr) = do
  mapM_ (requireI [Prim Cert]) cs
  arrt <- lookupType arr
  let rank = arrayRank arrt
  when (length perm /= rank || sort perm /= [0..rank-1]) $
    bad $ PermutationError perm rank $ Just arr

checkPrimOp (Split cs sizeexps arrexp) = do
  mapM_ (requireI [Prim Cert]) cs
  mapM_ (require [Prim int32]) sizeexps
  void $ checkArrIdent arrexp

checkPrimOp (Concat cs arr1exp arr2exps ressize) = do
  mapM_ (requireI [Prim Cert]) cs
  arr1t  <- checkArrIdent arr1exp
  arr2ts <- mapM checkArrIdent arr2exps
  let success = all (== stripArray 1 arr1t) $
                map (stripArray 1) arr2ts
  unless success $
    bad $ TypeError $
    "Types of arguments to concat do not match.  Got " ++
    pretty arr1t ++ " and " ++ intercalate ", " (map pretty arr2ts)
  require [Prim int32] ressize

checkPrimOp (Copy e) =
  void $ checkArrIdent e

checkPrimOp (Assert e _) =
  require [Prim Bool] e

checkPrimOp (Partition cs _ flags arrs) = do
  mapM_ (requireI [Prim Cert]) cs
  flagst <- lookupType flags
  unless (rowType flagst == Prim int32) $
    bad $ TypeError $ "Flag array has type " ++ pretty flagst ++ "."
  forM_ arrs $ \arr -> do
    arrt <- lookupType arr
    unless (arrayRank arrt > 0) $
      bad $ TypeError $
      "Array argument " ++ pretty arr ++
      " to partition has type " ++ pretty arrt ++ "."

checkExp :: Checkable lore =>
            Exp lore -> TypeM lore ()

checkExp (PrimOp op) = checkPrimOp op

checkExp (If e1 e2 e3 ts) = do
  require [Prim Bool] e1
  _ <- checkBody e2 `alternative` checkBody e3
  ts2 <- bodyExtType e2
  ts3 <- bodyExtType e3
  unless ((ts2 `generaliseExtTypes` ts3) `subtypesOf` ts) $
    bad $ TypeError $
    unlines ["If-expression branches have types",
             "  " ++ prettyTuple ts2 ++ ", and",
             "  " ++ prettyTuple ts3,
             "But the annotation is",
             "  " ++ prettyTuple ts]

checkExp (Apply fname args rettype_annot) = do
  (rettype_derived, paramtypes) <- lookupFun fname $ map fst args
  argflows <- mapM (checkArg . fst) args
  when (rettype_derived /= rettype_annot) $
    bad $ TypeError $ "Expected apply result type " ++ pretty rettype_derived
    ++ " but annotation is " ++ pretty rettype_annot
  checkFuncall (Just fname) paramtypes argflows

checkExp (DoLoop ctxmerge valmerge form loopbody) = do
  let merge = ctxmerge ++ valmerge
      (mergepat, mergeexps) = unzip merge
  mergeargs <- mapM checkArg mergeexps

  funparams <- case form of
    ForLoop loopvar boundexp -> do
      iparam <- primFParam loopvar int32
      let funparams = iparam : mergepat
          paramts   = map paramDeclType funparams

      boundarg <- checkArg boundexp
      checkFuncall Nothing paramts $ boundarg : mergeargs
      return funparams
    WhileLoop cond -> do
      case find ((==cond) . paramName . fst) merge of
        Just (condparam,_) ->
          unless (paramType condparam == Prim Bool) $
          bad $ TypeError $
          "Conditional '" ++ pretty cond ++ "' of while-loop is not boolean, but " ++
          pretty (paramType condparam) ++ "."
        Nothing ->
          bad $ TypeError $
          "Conditional '" ++ pretty cond ++ "' of while-loop is not a merge varible."
      let funparams = mergepat
          paramts   = map paramDeclType funparams
      checkFuncall Nothing paramts mergeargs
      return funparams

  let rettype = map paramDeclType mergepat
      consumable = [ (paramName param, mempty)
                   | param <- mergepat,
                     unique $ paramDeclType param
                   ]

  context "Inside the loop body" $
    checkFun' (nameFromString "<loop body>",
               staticShapes rettype,
               funParamsToNameInfos funparams,
               loopbody) consumable $ do
        checkFunParams funparams
        checkBody loopbody
        bodyt <- map (`toDecl` Unique) <$> bodyExtType loopbody
        unless (map rankShaped bodyt `subtypesOf`
                map rankShaped (staticShapes rettype)) $
          bad $ ReturnTypeError (nameFromString "<loop body>")
          (map fromDecl $ staticShapes rettype)
          (map fromDecl bodyt)

checkExp (Op op) = checkOp op

checkSOACArrayArgs :: Checkable lore =>
                      SubExp -> [VName] -> TypeM lore [Arg]
checkSOACArrayArgs width vs =
  forM vs $ \v -> do
    (vt, v') <- checkSOACArrayArg v
    let argSize = arraySize 0 vt
    unless (argSize == width) $
      bad $ TypeError $
      "SOAC argument " ++ pretty v ++ " has outer size " ++
      pretty argSize ++ ", but width of SOAC is " ++
      pretty width
    return v'
  where checkSOACArrayArg ident = do
          (t, als) <- checkArg $ Var ident
          case peelArray 1 t of
            Nothing -> bad $ TypeError $
                       "SOAC argument " ++ pretty ident ++ " is not an array"
            Just rt -> return (t, (rt, als))

checkType :: Checkable lore =>
             TypeBase Shape u -> TypeM lore ()
checkType = mapM_ checkSubExp . arrayDims

checkExtType :: Checkable lore =>
                TypeBase ExtShape u
             -> TypeM lore ()
checkExtType = mapM_ checkExtDim . extShapeDims . arrayShape
  where checkExtDim (Free se) = void $ checkSubExp se
        checkExtDim (Ext _)   = return ()

checkCmpOp :: Checkable lore =>
              CmpOp -> SubExp -> SubExp
           -> TypeM lore ()
checkCmpOp (CmpEq t) x y = do
  require [Prim t] x
  require [Prim t] y
  matchSubExpTypes x y
checkCmpOp (CmpUlt t) x y = checkBinOpArgs (IntType t) x y
checkCmpOp (CmpUle t) x y = checkBinOpArgs (IntType t) x y
checkCmpOp (CmpSlt t) x y = checkBinOpArgs (IntType t) x y
checkCmpOp (CmpSle t) x y = checkBinOpArgs (IntType t) x y
checkCmpOp (FCmpLt t) x y = checkBinOpArgs (FloatType t) x y
checkCmpOp (FCmpLe t) x y = checkBinOpArgs (FloatType t) x y

checkBinOpArgs :: Checkable lore =>
                  PrimType -> SubExp -> SubExp -> TypeM lore ()
checkBinOpArgs t e1 e2 = do
  require [Prim t] e1
  require [Prim t] e2

checkPatElem :: Checkable lore =>
                PatElem (LetAttr lore) -> TypeM lore ()
checkPatElem (PatElem name bindage attr) = do
  checkBindage bindage
  checkLetBoundLore name attr

checkBindage :: Checkable lore =>
                Bindage -> TypeM lore ()
checkBindage BindVar = return ()
checkBindage (BindInPlace cs src is) = do
  mapM_ (requireI [Prim Cert]) cs
  srct <- lookupType src
  mapM_ (require [Prim int32]) is

  consume =<< lookupAliases src

  -- Check that the new value has the same type as what is already
  -- there (It does not have to be unique, though.)
  case peelArray (length is) srct of
    Nothing -> bad $ IndexingError (arrayRank srct) (length is)
    Just _  -> return ()

checkBinding :: Checkable lore =>
                Pattern lore -> Exp lore
             -> TypeM lore a
             -> TypeM lore a
checkBinding pat e m = do
  context ("When matching\n" ++ message "  " pat ++ "\nwith\n" ++ message "  " e) $
    matchPattern pat e
  binding (scopeOf pat) $ do
    mapM_ checkPatElem (patternElements $ removePatternAliases pat)
    m

matchExtPattern :: Checkable lore =>
                   [PatElem (LetAttr (Aliases lore))]
                -> [ExtType] -> TypeM lore ()
matchExtPattern pat ts = do
  (ts', restpat, _) <- liftEitherS $ patternContext pat ts
  unless (length restpat == length ts') $
    bad $ InvalidPatternError (Pattern [] pat) ts Nothing
  evalStateT (zipWithM_ checkBinding' restpat ts') []
  where checkBinding' patElem@(PatElem name _ _) t = do
          lift $ checkAnnotation ("binding of variable " ++ textual name)
            (patElemRequires patElem) t
          add name

        add name = do
          seen <- gets $ elem name
          if seen
            then lift $ bad $ DupPatternError name
            else modify (name:)

matchExtReturnType :: Checkable lore =>
                      Name -> [ExtType] -> Result
                   -> TypeM lore ()
matchExtReturnType fname rettype ses = do
  ts <- staticShapes <$> mapM subExpType ses
  unless (ts `subtypesOf` rettype) $
    bad $ ReturnTypeError fname rettype ts

patternContext :: Typed attr =>
                  [PatElemT attr] -> [ExtType] ->
                  Either String ([Type], [PatElemT attr], [PatElemT attr])
patternContext pat rt = do
  (rt', (restpat,_), shapepat) <- runRWST (mapM extract rt) () (pat, HM.empty)
  return (rt', restpat, shapepat)
  where extract t = setArrayShape t <$> Shape <$>
                    mapM extract' (extShapeDims $ arrayShape t)
        extract' (Free se) = return se
        extract' (Ext x)   = correspondingVar x
        correspondingVar x = do
          (remnames, m) <- get
          case (remnames, HM.lookup x m) of
            (_, Just v) -> return $ Var $ patElemName v
            (v:vs, Nothing)
              | Prim (IntType Int32) <- patElemType v -> do
                tell [v]
                put (vs, HM.insert x v m)
                return $ Var $ patElemName v
            (_, Nothing) ->
              lift $ Left "Pattern cannot match context"

validApply :: ArrayShape shape =>
              [TypeBase shape Uniqueness]
           -> [TypeBase shape NoUniqueness]
           -> Bool
validApply expected got =
  length got == length expected &&
  and (zipWith subtypeOf
       (map rankShaped got)
       (map (fromDecl . rankShaped) expected))

type Arg = (Type, Names)

argType :: Arg -> Type
argType (t, _) = t

argAliases :: Arg -> Names
argAliases (_, als) = als

checkArg :: Checkable lore =>
            SubExp -> TypeM lore Arg
checkArg arg = do als <- subExpAliasesM arg
                  argt <- subExpType arg
                  return (argt, als)

checkFuncall :: Checkable lore =>
                Maybe Name
             -> [DeclType] -> [Arg]
             -> TypeM lore ()
checkFuncall fname paramts args = do
  let argts = map argType args
  unless (validApply paramts argts) $
    bad $ ParameterMismatch fname
          (map fromDecl paramts) $
          map argType args
  forM_ (zip (map diet paramts) args) $ \(d, (_, als)) ->
    occur [consumption (consumeArg als d)]
  where consumeArg als Consume = als
        consumeArg _   Observe = mempty

checkLambda :: Checkable lore =>
               Lambda lore -> [Arg] -> TypeM lore ()
checkLambda (Lambda params body rettype) args = do
  let fname = nameFromString "<anonymous>"
  if length params == length args then do
    checkFuncall Nothing
      (map ((`toDecl` Nonunique) . paramType) params) args
    let consumable = zip (map paramName params) (map argAliases args)
    checkFun' (fname,
               staticShapes $ map (`toDecl` Nonunique) rettype,
               [ (paramName param,
                  LParamInfo $ paramAttr param)
               | param <- params ],
               body) consumable $ do
      checkLambdaParams params
      mapM_ checkType rettype
      checkLambdaBody rettype body
  else bad $ TypeError $ "Anonymous function defined with " ++ show (length params) ++ " parameters, but expected to take " ++ show (length args) ++ " arguments."

checkExtLambda :: Checkable lore =>
                  ExtLambda lore -> [Arg] -> TypeM lore ()
checkExtLambda (ExtLambda params body rettype) args =
  if length params == length args then do
    checkFuncall Nothing (map ((`toDecl` Nonunique) . paramType) params) args
    let fname = nameFromString "<anonymous>"
        consumable = zip (map paramName params) (map argAliases args)
    checkFun' (fname,
               map (`toDecl` Nonunique) rettype,
               [ (paramName param,
                  LParamInfo $ paramAttr param)
               | param <- params ],
               body) consumable $
      checkBindings (bodyBindings body) $ do
        checkResult $ bodyResult body
        matchExtReturnType fname rettype $ bodyResult body
    else bad $ TypeError $
         "Existential lambda defined with " ++ show (length params) ++
         " parameters, but expected to take " ++ show (length args) ++ " arguments."

-- | The class of lores that can be type-checked.
class (Attributes lore, CanBeAliased (Op lore)) => Checkable lore where
  checkExpLore :: ExpAttr lore -> TypeM lore ()
  checkBodyLore :: BodyAttr lore -> TypeM lore ()
  checkFParamLore :: VName -> FParamAttr lore -> TypeM lore ()
  checkLParamLore :: VName -> LParamAttr lore -> TypeM lore ()
  checkLetBoundLore :: VName -> LetAttr lore -> TypeM lore ()
  checkRetType :: AST.RetType lore -> TypeM lore ()
  checkOp :: OpWithAliases (Op lore) -> TypeM lore ()
  matchPattern :: Pattern lore -> Exp lore -> TypeM lore ()
  primFParam :: VName -> PrimType -> TypeM lore (AST.FParam (Aliases lore))
  primLParam :: VName -> PrimType -> TypeM lore (AST.LParam (Aliases lore))
  matchReturnType :: Name -> RetType lore -> AST.Result -> TypeM lore ()

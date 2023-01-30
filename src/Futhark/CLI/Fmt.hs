-- | @futhark fmt@
module Futhark.CLI.Fmt (main) where

import Futhark.Util.Options


-- | Run @futhark fmt@
main :: String -> [String] -> IO ()
main = mainWithOptions () [] "programs..." $ \args () ->
  case args of
    [file] -> Just $ do
      mapM_ (putStr . show) file
    _ -> Nothing


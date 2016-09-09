-- Indexing into a concat.  The simplifier should remove the concat.
-- ==
-- input { [1,2,3] [4,5,6] [7,8,9] 1 } output { 2 }
-- input { [1,2,3] [4,5,6] [7,8,9] 4 } output { 5 }
-- input { [1,2,3] [4,5,6] [7,8,9] 7 } output { 8 }
-- input { [1,2,3] [4,5,6] [7,8,9] 9 } error: .*
-- input { [1,2,3] [4,5,6] [7,8,9] -1 } error: .*
-- structure { Concat 0 }

fun main(as: []int, bs: []int, cs: []int, i: int): int =
  let ds = concat as bs cs
  in ds[i]

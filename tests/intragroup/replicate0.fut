-- Written in a contrived way to make the replicate actually show up.
-- ==
-- random input { [1][256]i32 } auto output
-- random input { [100][256]i32 } auto output
-- random input { [100][512]i32 } auto output

let main = map i32.sum >-> map (replicate 2000)
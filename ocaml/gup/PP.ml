include CCFormat
let list pp = within "[" "]" (list ~sep:(return "; ") pp)
let array pp = within "[|" "|]" (array ~sep:(return "; ") pp)
let option = opt
let pair p1 p2 = within "(" ")" (pair p1 p2)

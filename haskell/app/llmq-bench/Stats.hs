-- | The statistics every llmq-bench figure is reported with.
--
-- Part of llmq-bench; Main's header says what is measured and why.
--
-- ============================================================================
-- WHAT A FIGURE CARRIES
-- ============================================================================
--
-- Every repeated measurement is kept as its raw samples and summarised as
-- n, median, mean, standard deviation, coefficient of variation, the 95%
-- confidence interval of the mean (Student's t, because n is small), the
-- quartiles, and the extremes. The median is the headline number, because
-- one slow sample (a page fault storm, a background job) moves the mean and
-- barely moves the median. The interval and the raw samples are there so a
-- reader can recompute the headline and see its spread.
--
-- ============================================================================
-- WHEN TO STOP REPEATING
-- ============================================================================
--
-- `relHalfWidth` is the half-width of the 95% interval divided by the mean.
-- The protocol repeats a measurement until that is at or below its target
-- (5% by default) or its repetition limit, which is the sequential stopping
-- rule hyperfine and criterion-style harnesses use in place of a fixed
-- sample count.
--
-- ============================================================================
-- FITS
-- ============================================================================
--
-- `fitPoly` is ordinary least squares of a polynomial, solved from the
-- normal equations by Gaussian elimination with partial pivoting. It is
-- used on at most a few dozen points with x in thousands of tokens, where
-- that is well conditioned. It reports R squared and the root mean square
-- residual, so a fit that does not describe the data says so.
module Stats
  ( Summary (..)
  , summarise
  , summaryJSON
  , relHalfWidth
  , median
  , Fit (..)
  , fitPoly
  , fitJSON
  , evalFit
  ) where

import Data.Aeson (Value, object, (.=))
import Data.List (sort)

data Summary = Summary
  { n :: Int
  , median' :: Double
  , mean :: Double
  , sd :: Double
  , ciLo :: Double
  , ciHi :: Double
  , p25 :: Double
  , p75 :: Double
  , lo :: Double
  , hi :: Double
  , samples :: [Double]
  }

summarise :: [Double] -> Maybe Summary
summarise [] = Nothing
summarise xs =
  let k = length xs
      m = sum xs / fromIntegral k
      s = stdDev xs
      half = if k >= 2 then tCrit (k - 1) * s / sqrt (fromIntegral k) else 0
      sorted = sort xs
   in Just
        Summary
          { n = k
          , median' = quantile 0.5 sorted
          , mean = m
          , sd = s
          , ciLo = m - half
          , ciHi = m + half
          , p25 = quantile 0.25 sorted
          , p75 = quantile 0.75 sorted
          , lo = head sorted
          , hi = last sorted
          , samples = xs
          }

summaryJSON :: Summary -> Value
summaryJSON s =
  object
    [ "n" .= s.n
    , "median" .= r4 s.median'
    , "mean" .= r4 s.mean
    , "sd" .= r4 s.sd
    , "cv" .= (if s.mean /= 0 then r4 (s.sd / abs s.mean) else 0)
    , "ci95" .= [r4 s.ciLo, r4 s.ciHi]
    , "p25" .= r4 s.p25
    , "p75" .= r4 s.p75
    , "min" .= r4 s.lo
    , "max" .= r4 s.hi
    , "samples" .= map r4 s.samples
    ]

-- | Half-width of the 95% interval of the mean over the mean. Nothing with
-- fewer than two samples or a zero mean.
relHalfWidth :: [Double] -> Maybe Double
relHalfWidth xs
  | k < 2 = Nothing
  | m == 0 = Nothing
  | otherwise = Just (tCrit (k - 1) * stdDev xs / sqrt (fromIntegral k) / abs m)
  where
    k = length xs
    m = sum xs / fromIntegral k

median :: [Double] -> Maybe Double
median [] = Nothing
median xs = Just (quantile 0.5 (sort xs))

-- | Type 7 quantile (linear interpolation between order statistics), the
-- default in R and numpy. The list must be sorted and non-empty.
quantile :: Double -> [Double] -> Double
quantile p sorted =
  let k = length sorted
      h = p * fromIntegral (k - 1)
      i = floor h :: Int
      frac = h - fromIntegral i
      at j = sorted !! max 0 (min (k - 1) j)
   in at i + frac * (at (i + 1) - at i)

stdDev :: [Double] -> Double
stdDev xs
  | k < 2 = 0
  | otherwise = sqrt (sum [(x - m) ^ (2 :: Int) | x <- xs] / fromIntegral (k - 1))
  where
    k = length xs
    m = sum xs / fromIntegral k

-- | Two-sided 97.5% quantile of Student's t for the given degrees of freedom.
tCrit :: Int -> Double
tCrit df
  | df <= 0 = 0
  | df <= length table = table !! (df - 1)
  | otherwise = 1.96 + 2.4 / fromIntegral df
  where
    table =
      [ 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228
      , 2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086
      , 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042
      ]

-- | A least-squares polynomial: coefficients from the constant term up.
data Fit = Fit
  { coefficients :: [Double]
  , rSquared :: Double
  , rmse :: Double
  , points :: Int
  }

-- | Fit a polynomial of the given degree. Nothing when there are fewer
-- distinct x values than coefficients, or the system is singular.
fitPoly :: Int -> [(Double, Double)] -> Maybe Fit
fitPoly degree pts
  | length (distinct (map fst pts)) < degree + 1 = Nothing
  | otherwise = do
      let k = degree + 1
          row x = [x ^ j | j <- [0 .. degree]]
          ata = [[sum [row x !! i * row x !! j | (x, _) <- pts] | j <- [0 .. k - 1]] | i <- [0 .. k - 1]]
          aty = [sum [row x !! i * y | (x, y) <- pts] | i <- [0 .. k - 1]]
      cs <- solve ata aty
      let predicted = [sum (zipWith (*) cs (row x)) | (x, _) <- pts]
          ys = map snd pts
          ym = sum ys / fromIntegral (length ys)
          ssRes = sum [(y - p) ^ (2 :: Int) | (y, p) <- zip ys predicted]
          ssTot = sum [(y - ym) ^ (2 :: Int) | y <- ys]
      pure
        Fit
          { coefficients = cs
          , rSquared = if ssTot > 0 then 1 - ssRes / ssTot else 1
          , rmse = sqrt (ssRes / fromIntegral (length pts))
          , points = length pts
          }
  where
    distinct = foldr (\x acc -> if any (\y -> abs (x - y) < 1e-9) acc then acc else x : acc) []

evalFit :: Fit -> Double -> Double
evalFit f x = sum (zipWith (\c j -> c * x ^ j) f.coefficients [0 :: Int ..])

fitJSON :: Fit -> Value
fitJSON f =
  object
    [ "coefficients" .= map r6 f.coefficients
    , "r2" .= r4 f.rSquared
    , "rmse" .= r4 f.rmse
    , "points" .= f.points
    ]

-- | Gaussian elimination with partial pivoting.
solve :: [[Double]] -> [Double] -> Maybe [Double]
solve a b = backSub =<< eliminate (zipWith (\r v -> r <> [v]) a b)
  where
    eliminate [] = Just []
    eliminate rows =
      let pivotRow = foldr1 (\r acc -> if abs (head r) > abs (head acc) then r else acc) rows
          rest = deleteFirst pivotRow rows
       in if abs (head pivotRow) < 1e-12
            then Nothing
            else do
              let reduce r = zipWith (\x p -> x - (head r / head pivotRow) * p) (tail r) (tail pivotRow)
              below <- eliminate (map reduce rest)
              pure (pivotRow : map (0 :) below)
    deleteFirst _ [] = []
    deleteFirst x (y : ys) = if x == y then ys else y : deleteFirst x ys
    backSub rows = go (reverse (zipWith drop [0 ..] rows)) []
      where
        go [] acc = Just acc
        go (r : rs) acc =
          let coef = head r
              rhs = last r
              known = sum (zipWith (*) (init (tail r)) acc)
           in if abs coef < 1e-12 then Nothing else go rs ((rhs - known) / coef : acc)

r4 :: Double -> Double
r4 x = fromIntegral (round (x * 10000) :: Integer) / 10000

r6 :: Double -> Double
r6 x = fromIntegral (round (x * 1000000) :: Integer) / 1000000

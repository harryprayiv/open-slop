module Main (main) where

import Probe (probes)
import Test.Tasty

main :: IO ()
main = defaultMain probes
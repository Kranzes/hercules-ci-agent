module Main where

import           Prelude
import           Test.Hspec.Runner
import           Test.Hspec.Formatters
import qualified Spec

main :: IO ()
main = hspecWith config Spec.spec
  where config = defaultConfig { configColorMode = ColorAlways }

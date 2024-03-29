module Main where

import GHC.Profiler.UI
import GHC.Profiler.UI.Monad
import GHC.Profiler.State

import qualified Network.Wai.Handler.Warp as Warp

main :: IO ()
main = do
  -- initialize application state
  state <- initAppState

  -- run web UI
  putStrLn "Running ghc-profiler on port 3000"
  mstate <- initMState state
  Warp.run 3000 (httpApp mstate)

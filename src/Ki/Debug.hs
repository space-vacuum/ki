module Ki.Debug
  ( debug,
  )
where

import Control.Concurrent
import System.IO.Unsafe (unsafePerformIO)
import Prelude

debug :: Monad m => String -> m ()
debug message =
  unsafePerformIO output `seq` pure ()
  where
    output :: IO ()
    output = do
      threadId <- myThreadId
      withMVar lock \_ -> putStrLn ("[" ++ show threadId ++ "] " ++ message)

lock :: MVar ()
lock =
  unsafePerformIO (newMVar ())
{-# NOINLINE lock #-}

module Ki.Thread
  ( Thread (..),
    async,
    asyncWithUnmask,
    await,
    awaitSTM,
    awaitFor,
    fork,
    fork_,
    forkWithUnmask,
    forkWithUnmask_,
  )
where

import Control.Exception (Exception (fromException))
import qualified Ki.Context as Context
import Ki.Duration (Duration)
import Ki.Prelude
import Ki.Scope (Scope (Scope))
import qualified Ki.Scope as Scope
import Ki.Timeout (timeoutSTM)

-- | A running __thread__.
data Thread a
  = Thread !ThreadId !(STM a)
  deriving stock (Functor, Generic)

instance Eq (Thread a) where
  Thread id1 _ == Thread id2 _ =
    id1 == id2

instance Ord (Thread a) where
  compare (Thread id1 _) (Thread id2 _) =
    compare id1 id2

-- | Create a __thread__ within a __scope__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
async :: Scope -> IO a -> IO (Thread (Either SomeException a))
async scope action =
  asyncWithRestore scope \restore -> restore action

-- | Variant of 'async' that provides the __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
asyncWithUnmask :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread (Either SomeException a))
asyncWithUnmask scope action =
  asyncWithRestore scope \restore -> restore (action unsafeUnmask)

asyncWithRestore :: forall a. Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread (Either SomeException a))
asyncWithRestore scope action = do
  resultVar <- newEmptyTMVarIO
  childThreadId <- Scope.scopeFork scope action (putTMVarIO resultVar)
  pure (Thread childThreadId (readTMVar resultVar))

-- | Wait for a __thread__ to finish.
await :: Thread a -> IO a
await =
  atomically . awaitSTM

-- | @STM@ variant of 'await'.
awaitSTM :: Thread a -> STM a
awaitSTM (Thread _ action) =
  action

-- | Variant of 'await' that gives up after the given duration.
awaitFor :: Thread a -> Duration -> IO (Maybe a)
awaitFor thread duration =
  timeoutSTM duration (pure . Just <$> awaitSTM thread) (pure Nothing)

-- | Create a __thread__ within a __scope__.
--
-- If the __thread__ throws an exception, the exception is immediately propagated up the call tree to the __thread__
-- that opened its __scope__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork :: Scope -> IO a -> IO (Thread a)
fork scope action =
  forkWithRestore scope \restore -> restore action

-- | Variant of 'fork' that does not return a handle to the created __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork_ :: Scope -> IO () -> IO ()
fork_ scope action =
  forkWithRestore_ scope \restore -> restore action

-- | Variant of 'fork' that provides the __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
forkWithUnmask scope action =
  forkWithRestore scope \restore -> restore (action unsafeUnmask)

-- | Variant of 'forkWithUnmask' that does not return a handle to the created __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask_ :: Scope -> ((forall x. IO x -> IO x) -> IO ()) -> IO ()
forkWithUnmask_ scope action =
  forkWithRestore_ scope \restore -> restore (action unsafeUnmask)

forkWithRestore :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
forkWithRestore scope action = do
  parentThreadId <- myThreadId
  resultVar <- newEmptyTMVarIO
  childThreadId <-
    Scope.scopeFork scope action \case
      Left exception ->
        -- Intentionally don't fill the result var.
        --
        -- Prior to 0.2.0, we did put a 'Left exception' in the result var, so that if another thread awaited it, we'd
        -- promptly deliver them the exception that brought this thread down. However, that exception was *wrapped* in
        -- a 'ThreadFailed' exception, so the caller could distinguish between async exceptions *delivered to them* and
        -- async exceptions coming *synchronously* out of the call to 'await'.
        --
        -- At some point I reasoned that if one is following some basic structured concurrency guidelines, and not doing
        -- weird/complicated things like passing threads around, then it is likely that a failed forked thread is just
        -- about to propagate its exception to all callers of 'await' (presumably, its direct parent).
        --
        -- Might GHC deliver a BlockedIndefinitelyOnSTM in the meantime, though?
        maybePropagateException scope parentThreadId exception
      Right result -> putTMVarIO resultVar result
  pure (Thread childThreadId (readTMVar resultVar))

forkWithRestore_ :: Scope -> ((forall x. IO x -> IO x) -> IO ()) -> IO ()
forkWithRestore_ scope action = do
  parentThreadId <- myThreadId
  _childThreadId <- Scope.scopeFork scope action (onLeft (maybePropagateException scope parentThreadId))
  pure ()

maybePropagateException :: Scope -> ThreadId -> SomeException -> IO ()
maybePropagateException Scope {closedVar, context} parentThreadId exception =
  whenM shouldPropagateException (throwTo parentThreadId (Scope.ThreadFailed exception))
  where
    shouldPropagateException :: IO Bool
    shouldPropagateException =
      case fromException exception of
        -- Our scope is (presumably) closing, so don't propagate this exception that presumably just came from our
        -- parent. But if our scope's closedVar isn't True, that means this 'ScopeClosing' definitely came from
        -- somewhere else...
        Just Scope.ScopeClosing -> not <$> readTVarIO closedVar
        Nothing ->
          case fromException exception of
            -- We (presumably) are honoring our own cancellation request, so don't propagate that either.
            -- It's a bit complicated looking because we *do* want to throw this token if we (somehow) threw it
            -- "inappropriately" in the sense that it wasn't ours to throw - it was smuggled from elsewhere.
            Just token -> atomically ((/= token) <$> Context.contextCancelTokenSTM context <|> pure True)
            Nothing -> pure True

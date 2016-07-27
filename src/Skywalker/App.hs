{-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ScopedTypeVariables, OverloadedStrings, JavaScriptFFI, GADTs, FlexibleInstances #-}
module Skywalker.App where

import Control.Monad.State
import Control.Monad.IO.Class
import Control.Concurrent.MVar
import Control.Concurrent.STM

import Data.ByteString hiding (reverse)
import qualified Data.Map as M

-- import the different library for JSON
#if defined(ghcjs_HOST_OS)
import JavaScript.JSON.Types
import JavaScript.JSON.Types.Class
import JavaScript.JSON.Types.Internal
import JavaScript.JSON.Types.Instances
import JavaScript.Web.WebSocket
import JavaScript.Web.MessageEvent

import Control.Monad.Reader

import Data.IORef
import Data.JSString hiding (reverse)
-- a dummy websocket connection used only on server side
data Connection

#else
import Network.WebSockets
import Data.Aeson

data WebSocketRequest
#endif

newtype URL = URL {
#if defined(ghcjs_HOST_OS)
  urlString :: JSString
#else
  urlString :: String
#endif
}

-- easier to read alias for JSON value
type JSON = Value

fromResult :: Result a -> a
fromResult (Success a) = a
fromResult _ = undefined

-- a special data type for forcing the use of runClient as the last
-- operation in App monad
data AppDone = AppDone

-- CallID represents a single remote server function available to the client side.
type CallID = Int

-- Nonce is a tag used represent a specific remote function call, because each
-- client can call the same remote function any times and we need to distinguish
-- between each call
type Nonce = Int

-- a remote method is an IO action that accepts a list of JSON and return a JSON result
type Method = [JSON] -> Server JSON

-- the state stored in the App monad, the first element, CallID, represents the next
-- CallID available to be used for defining a new remote function. The second element
-- is a map of all the defined remote functions
type AppState = (CallID, M.Map CallID Method)

-- the top-level App monad for the whole app
newtype App a = App { unApp :: StateT AppState IO a }
              deriving (Functor, Applicative, Monad, MonadIO, MonadState AppState)

-- run the top-level App monad and return an IO action. This should be used at the begining
-- of the whole application
runApp :: App AppDone -> IO ()
runApp = void . flip runStateT (0, M.empty) . unApp

-- define a value that be used in remote functions
class Remotable a where
  mkRemote :: a -> Method

instance (ToJSON a) => Remotable (Server a) where
  mkRemote m _ = fmap toJSON m

instance (FromJSON a, Remotable b) => Remotable (a -> b) where
  mkRemote f (x:xs) = mkRemote (f jx) xs
    where Success jx = fromJSON x

#if defined(ghcjs_HOST_OS)
-- on the client side, we don't care about Server values, so it's just a dummy value
data Server a = ServerDummy

instance Functor Server where
  fmap _ _ = ServerDummy

instance Applicative Server where
  pure _ = ServerDummy
  _ <*> _ = ServerDummy

instance Monad Server where
  return _ = ServerDummy
  _ >>= _ = ServerDummy

instance MonadIO Server where
  liftIO _ = ServerDummy

-- for a remote value, we just need to remember the CallID and arguments for it
data Remote a = Remote CallID [JSON]
#else
-- Server Monad is just a wrapper over m
newtype Server a = Server { runServerM :: IO a }
                 deriving (Functor, Applicative, Monad, MonadIO)

-- remote values are not interested on the server side either
data Remote a = RemoteDummy
#endif

(<.>) :: ToJSON a => Remote (a -> b) -> a -> Remote b
#if defined(ghcjs_HOST_OS)
(Remote callId args) <.> arg = Remote callId (toJSON arg : args)
#else
_ <.> _ = RemoteDummy
#endif

-- convert a Remotable value to a Remote
remote :: Remotable a => a -> App (Remote a)
#if defined(ghcjs_HOST_OS)
-- client side, only the CallID is interesting to us, so just remember the id in
-- the Remote value. Don't forget to update the next available CallID
remote _ = do
  (nextId, remotes) <- get
  put (nextId + 1, remotes)
  return (Remote nextId [])
#else
-- server side, not only update the CallId, but also convert the argument value
-- into a Remote and store it in the AppState
remote f = do
  (nextId, remotes) <- get
  put (nextId + 1, M.insert nextId (mkRemote f) remotes)
  return RemoteDummy
#endif

-- lift a server side action into the App monad, only takes effect server side
liftServerIO :: IO a -> App (Server a)
#if defined(ghcjs_HOST_OS)
liftServerIO _ = return ServerDummy
#else
liftServerIO m = liftIO m >>= return . return
#endif

-- Client side definition
#if defined(ghcjs_HOST_OS)
type DispatchCenter = M.Map Nonce (MVar JSON)
data ClientState = ClientState {
    csNonce      :: TVar Nonce,
    csDispCenter :: TVar DispatchCenter,
    csWebSocket  :: TVar WebSocket
    }

-- define a client environment type with a websocket as well as a variable type
type ClientEnv a = (URL, a)
-- a (Client m e a) monad value means a monad with (ClientEnv e) environment,
-- ClientState state, a monad m inside and return value a
type Client e m = ReaderT (ClientEnv e) (StateT ClientState m)
#else
data Client e m a where
  ClientDummy :: Monad m => Client e m a

instance Monad m => Functor (Client e m) where
  fmap _ _ = ClientDummy

instance Monad m => Applicative (Client e m) where
  pure _ = ClientDummy
  _ <*> _ = ClientDummy

instance Monad m => Monad (Client e m) where
  return _ = ClientDummy
  _ >>= _ = ClientDummy

instance Monad m => MonadIO (Client e m) where
  liftIO _ = ClientDummy
#endif

-- get the custom environment data inside Client monad
getClientEnv :: Monad m => Client e m e
#if defined(ghcjs_HOST_OS)
getClientEnv = snd <$> ask
#else
getClientEnv = undefined
#endif

onServer :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> Client e m a
#if defined(ghcjs_HOST_OS)
onServer (Remote identifier args) = do
  (nonce, mv) <- newResult
  wsTVar <- csWebSocket <$> get
  ws <- liftIO $ readTVarIO wsTVar
  wsSt <- liftIO $ getReadyState ws

  let sendMsg ws = do
          -- send the actual request and wait for the result
          liftIO $ send (encode $ toJSON (nonce, identifier, reverse args)) ws
          (fromResult . fromJSON) <$> (liftIO $ takeMVar mv)
  if wsSt == Connecting || wsSt == OPEN
      then sendMsg ws
      else do
      url <- fst <$> ask
      n <- csNonce <$> get
      mvarDispCenter <- csDispCenter <$> get
      newWs <- liftIO $ connect $ buildReq url mvarDispCenter
      liftIO $ atomically $ writeTVar wsTVar newWs
      sendMsg newWs

newResult :: (Monad m, MonadIO m) => Client e m (Nonce, MVar JSON)
newResult = do
  (ClientState mNonce mvarDispCenter ws) <- get
  mv <- liftIO newEmptyMVar
  nonce <- liftIO $ readTVarIO mNonce
  liftIO $ atomically $ do
      modifyTVar' mvarDispCenter (\m -> M.insert nonce mv m)
      writeTVar mNonce (nonce + 1)
  return (nonce, mv)
#else
onServer _ = ClientDummy
#endif

runClient :: URL -> e -> Client e IO a -> App AppDone
#if defined(ghcjs_HOST_OS)
runClient url env c = do
  mvarDispCenter <- liftIO $ atomically $ newTVar M.empty
  let req = buildReq url mvarDispCenter
  ws <- liftIO $ connect req
  wsTVar <- liftIO $ atomically $ newTVar ws
  mNonce <- liftIO $ atomically $ newTVar 0
  let defState = ClientState mNonce mvarDispCenter wsTVar
  liftIO $ runStateT (runReaderT c (url, env)) defState
  return AppDone

buildReq url mvarDispCenter = WebSocketRequest {
    url = urlString url,
    protocols = ["GHCJS.App"],
    onClose = Nothing,
    onMessage = Just (processServerMessage mvarDispCenter)
    }

processServerMessage mvarDispCenter evt = do
    -- only string data is supported, if it fails, it's a bug in the framework
    let StringData d = getData evt
    onServerMessage mvarDispCenter $ parseJSONString d

onServerMessage mvarDispCenter response = do
    let res = fromJSON response
    case res of
        Success (nonce :: Int, result :: JSON) -> do
            m <- readTVarIO mvarDispCenter
            putMVar (m M.! nonce) result
            atomically $ writeTVar mvarDispCenter (M.delete nonce m)
        Error e -> print e
 
-- import the javascript JSON.parse function to transform a js string to a JSON Value type
foreign import javascript unsafe "JSON['parse']($1)" parseJSONString :: JSString -> JSON
#else
runClient _ _ _ = return AppDone
#endif


type DBParam = ByteString

-- start the websocket server with db param, file path for static assets and port
onEvent :: Connection -> M.Map CallID Method -> JSON -> Server ()
#if defined(ghcjs_HOST_OS)
onEvent _ _ _ = ServerDummy
#else
-- server side dispatcher of client function calls
onEvent conn mapping incoming = do
  let Success (nonce :: Int, identifier :: CallID, args :: [JSON]) = fromJSON incoming
      Just f = M.lookup identifier mapping
  result <- f args
  liftIO $ sendTextData conn $ encode (nonce, result)
#endif


#if defined(ghcjs_HOST_OS)
websocketServer = undefined
#else
websocketServer remoteMapping pendingConn = do
  conn <- acceptRequestWith pendingConn (AcceptRequest (Just "GHCJS.App"))
  websocketHandler remoteMapping conn
  -- fork a new thread to send 'ping' control messages to the client every 3 seconds
  forkPingThread conn 3

websocketHandler remoteMapping conn = do
  msg <- receiveData conn
  let Just (m :: JSON) = decode msg
  runServerM $ onEvent conn remoteMapping m
  websocketHandler remoteMapping conn
#endif

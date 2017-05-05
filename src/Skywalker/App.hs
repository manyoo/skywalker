{-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ScopedTypeVariables, OverloadedStrings, JavaScriptFFI, GADTs, FlexibleInstances #-}
module Skywalker.App where

import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.IO.Class
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Data.Maybe (isJust, fromJust)
import Data.Default

import Data.ByteString hiding (reverse)
import qualified Data.Map as M

import Skywalker.UUID (UUID)
import qualified Skywalker.UUID as UUID

-- import the different library for JSON
#if defined(ghcjs_HOST_OS)
import JavaScript.JSON.Types
import JavaScript.JSON.Types.Class
import JavaScript.JSON.Types.Internal
import JavaScript.JSON.Types.Instances
import JavaScript.Web.WebSocket
import JavaScript.Web.MessageEvent

import Data.IORef
import Data.JSString hiding (reverse)
-- a dummy websocket connection used only on server side
data Connection

#else
import Control.Exception (SomeException, handle)

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

-- a UUID to represent a client app
type ClientID = UUID

-- MethodName is the name of a remote server function available to the client side.
type MethodName = String

-- Nonce is a tag used represent a specific remote function call, because each
-- client can call the same remote function any times and we need to distinguish
-- between each call
type Nonce = Int

-- a remote method is an IO action that accepts a list of JSON and return a JSON result
type Method = [JSON] -> Server JSON

-- specify whether the remote method is execuated in a sync, async or subscription based way
data MethodMode = MethodSync
                | MethodAsync
                | MethodSubscribe
                deriving Eq

-- the state stored in the App monad, it is a map of all the defined remote functions
type AppState = M.Map MethodName (MethodMode, Method)

-- the top-level App monad for the whole app
newtype App a = App { unApp :: StateT AppState IO a }
              deriving (Functor, Applicative, Monad, MonadIO, MonadState AppState)

-- run the top-level App monad and return an IO action. This should be used at the begining
-- of the whole application
runApp :: App AppDone -> IO ()
runApp = void . flip runStateT M.empty . unApp

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

-- for a remote value, we just need to remember the MethodName and arguments for it
data Remote a = Remote MethodName MethodMode [JSON]
#else
-- Server Monad is just a wrapper over IO
newtype ServerState = ServerState {
    ssConnection :: Maybe (TVar Connection)
    }

instance Default ServerState where
    def = ServerState Nothing

data ServerEnv = ServerEnv {
    seClientId     :: Maybe ClientID,
    seCurrentNonce :: Maybe Int
    }

instance Default ServerEnv where
    def = ServerEnv Nothing Nothing

type Server a = ReaderT ServerEnv (StateT ServerState IO) a

runServerM e st = flip evalStateT st . flip runReaderT e

-- remote values are not interested on the server side either
data Remote a = RemoteDummy
#endif

(<.>) :: ToJSON a => Remote (a -> b) -> a -> Remote b
#if defined(ghcjs_HOST_OS)
(Remote name mode args) <.> arg = Remote name mode (toJSON arg : args)
#else
_ <.> _ = RemoteDummy
#endif

-- convert a Remotable value to a Remote
remote :: Remotable a => MethodName -> a -> App (Remote a)
remote = remoteWithMode MethodSync

asyncRemote :: Remotable a => MethodName -> a -> App (Remote a)
asyncRemote = remoteWithMode MethodAsync

remoteChannel :: Remotable a => MethodName -> a -> App (Remote a)
remoteChannel = remoteWithMode MethodSubscribe

remoteWithMode :: Remotable a => MethodMode -> MethodName -> a -> App (Remote a)
#if defined(ghcjs_HOST_OS)
-- client side, just remember the name in the Remote value
remoteWithMode m n _ = return (Remote n m [])
#else
-- server side, convert the argument value into a Remote and store it in the AppState
remoteWithMode m n f = do
    remotes <- get
    when (M.member n remotes) (error $ "Remote method '" ++ show n ++ "' already defined.")
    put $ M.insert n (m, mkRemote f) remotes
    return RemoteDummy
#endif

-- lift a server side action into the App monad, only takes effect server side
liftServerIO :: IO a -> App (Server a)
#if defined(ghcjs_HOST_OS)
liftServerIO _ = return ServerDummy
#else
liftServerIO m = return <$> liftIO m
#endif

-- Client side definition
#if defined(ghcjs_HOST_OS)
type DispatchCenter = M.Map Nonce (MethodMode, MVar JSON)
data ClientState = ClientState {
    csNonce      :: TVar Nonce,
    csDispCenter :: TVar DispatchCenter,
    csWebSocket  :: TVar WebSocket
    }

-- define a client environment type with a websocket as well as a variable type
data ClientEnv a = ClientEnv {
    ceUrl      :: URL,
    ceClientId :: ClientID,
    ceCustom   :: a
    }
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
getClientEnv = ceCustom <$> ask
#else
getClientEnv = undefined
#endif

onServer :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> Client e m a
#if defined(ghcjs_HOST_OS)
onServer (Remote identifier mode args) = do
    (nonce, mv) <- newResult mode
    cid         <- ceClientId <$> ask
    wsTVar      <- csWebSocket <$> get
    ws          <- liftIO $ readTVarIO wsTVar
    wsSt        <- liftIO $ getReadyState ws

    let sendMsg ws = do
            -- send the actual request and wait for the result
            liftIO $ send (encode $ toJSON (nonce, identifier, cid, reverse args)) ws
            (fromResult . fromJSON) <$> (liftIO $ takeMVar mv)
    if wsSt == Connecting || wsSt == OPEN
    then sendMsg ws
    else do
        url <- ceUrl <$> ask
        n <- csNonce <$> get
        mvarDispCenter <- csDispCenter <$> get
        newWs <- liftIO $ connect $ buildReq url mvarDispCenter
        liftIO $ atomically $ writeTVar wsTVar newWs
        liftIO $ forkIO $ pingServer wsTVar cid
        sendMsg newWs

newResult :: (Monad m, MonadIO m) => MethodMode -> Client e m (Nonce, MVar JSON)
newResult mode = do
    (ClientState mNonce mvarDispCenter ws) <- get
    mv <- liftIO newEmptyMVar
    nonce <- liftIO $ readTVarIO mNonce
    liftIO $ atomically $ do
        modifyTVar' mvarDispCenter (\m -> M.insert nonce (mode, mv) m)
        writeTVar mNonce (nonce + 1)
    return (nonce, mv)
#else
onServer _ = ClientDummy
#endif

subscribeOnServer :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> (a -> IO ()) -> Client e m ()
#if defined (ghcjs_HOST_OS)
subscribeOnServer (Remote identifier mode args) cb = do
    (nonce, mv) <- newResult mode
    cid         <- ceClientId <$> ask
    wsTVar      <- csWebSocket <$> get
    ws          <- liftIO $ readTVarIO wsTVar
    wsSt        <- liftIO $ getReadyState ws

    let sendMsg ws = do
            -- send the actual request and wait for the result
            liftIO $ send (encode $ toJSON (nonce, identifier, cid, reverse args)) ws
            forever $ do
                res <- (fromResult . fromJSON) <$> (liftIO $ takeMVar mv)
                liftIO $ cb res
    if wsSt == Connecting || wsSt == OPEN
    then sendMsg ws
    else do
        url <- ceUrl <$> ask
        n <- csNonce <$> get
        mvarDispCenter <- csDispCenter <$> get
        newWs <- liftIO $ connect $ buildReq url mvarDispCenter
        liftIO $ atomically $ writeTVar wsTVar newWs
        liftIO $ forkIO $ pingServer wsTVar cid
        sendMsg newWs
#else
subscribeOnServer _ _ = ClientDummy
#endif

runClient :: URL -> e -> Client e IO a -> App AppDone
#if defined(ghcjs_HOST_OS)
runClient url env c = do
    mvarDispCenter <- liftIO $ atomically $ newTVar M.empty
    let req = buildReq url mvarDispCenter
    ws <- liftIO $ connect req
    wsTVar <- liftIO $ atomically $ newTVar ws
    mNonce <- liftIO $ atomically $ newTVar 1
    uid <- liftIO UUID.generateUUID

    liftIO $ forkIO (pingServer wsTVar uid)

    let defState = ClientState mNonce mvarDispCenter wsTVar
    liftIO $ runStateT (runReaderT c (ClientEnv url uid env)) defState
    return AppDone

pingServer wsTVar cid = do
    ws <- readTVarIO wsTVar
    wsSt <- getReadyState ws
    if wsSt == Connecting || wsSt == OPEN
        then do
        send (encode $ toJSON (0 :: Int, "ping" :: String, cid, [] :: [Int])) ws
        threadDelay 3000000
        pingServer wsTVar cid
        else return ()

buildReq url mvarDispCenter = WebSocketRequest {
    url = urlString url,
    protocols = ["GHCJSApp"],
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
            let (mode, mv) = m M.! nonce
            putMVar mv result
            when (mode /= MethodSubscribe) $ atomically $ writeTVar mvarDispCenter (M.delete nonce m)
        Error e -> print e

-- import the javascript JSON.parse function to transform a js string to a JSON Value type
foreign import javascript unsafe "JSON['parse']($1)" parseJSONString :: JSString -> JSON
#else
runClient _ _ _ = return AppDone
#endif

-- start the websocket server with db param, file path for static assets and port
onEvent :: M.Map MethodName (MethodMode, Method) -> JSON -> Server ()
#if defined(ghcjs_HOST_OS)
onEvent _ _ = ServerDummy
#else
-- server side dispatcher of client function calls
onEvent mapping incoming = do
    let Success (nonce :: Int, identifier :: MethodName, cid :: UUID, args :: [JSON]) = fromJSON incoming
    unless (nonce == 0 && identifier == "ping") $ do
        let Just (m, f) = M.lookup identifier mapping
            processEvt = f args >>= sendToClient nonce
            processSub = void $ f args
            newEnv = ServerEnv (Just cid) (Just nonce)
        st <- get
        case m of
            MethodSync -> processEvt
            MethodAsync -> liftIO $ void $ forkIO $ runServerM newEnv st processEvt
            MethodSubscribe -> liftIO $ void $ forkIO $ runServerM newEnv st processSub
#endif

#if defined(ghcjs_HOST_OS)
websocketServer = undefined
#else
websocketServer remoteMapping pendingConn = do
    conn <- acceptRequestWith pendingConn (AcceptRequest (Just "GHCJSApp") [])
    connTVar <- liftIO $ atomically $ newTVar conn
    websocketHandler remoteMapping connTVar
    -- fork a new thread to send 'ping' control messages to the client every 3 seconds
    forkPingThread conn 3

websocketHandler remoteMapping connTVar = do
    conn <- readTVarIO connTVar
    msg <- receiveData conn
    let Just (m :: JSON) = decode msg
    runServerM def (ServerState (Just connTVar)) $ onEvent remoteMapping m
    websocketHandler remoteMapping connTVar

sendToClient :: ToJSON a => Int -> a -> Server ()
sendToClient nonce res = do
    connTVarM <- ssConnection <$> get
    when (isJust connTVarM) $ do
        let connTVar = fromJust connTVarM
        conn <- liftIO $ readTVarIO connTVar
        void $ sendMessageToClient nonce res conn

sendMessageToClient :: ToJSON a => Int -> a -> Connection -> Server Bool
sendMessageToClient nonce res conn = liftIO $ handle handler $ sendTextData conn (encode (nonce, res)) >> return True
    where handler :: SomeException -> IO Bool
          handler _ = return False
#endif

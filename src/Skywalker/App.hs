{-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ScopedTypeVariables, OverloadedStrings, JavaScriptFFI, GADTs, FlexibleInstances, TypeFamilies #-}
module Skywalker.App where

import Control.Monad.State
import Control.Monad.IO.Class
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.STM

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

-- MethodName is the name of a remote server function available to the client side.
type MethodName = String

-- Nonce is a tag used represent a specific remote function call, because each
-- client can call the same remote function any times and we need to distinguish
-- between each call
type Nonce = Int

-- a remote method is an IO action that accepts a list of JSON and return a JSON result
type Method = [JSON] -> Server JSON

-- specify whether the remote method is execuated in a sync or async way
data MethodMode = MethodSync
                | MethodAsync

-- ChannelName is the name of a Subscribable channel
type ChannelName = String

-- Subscribable defines the class for all data models that can be used in
-- a channel
class Subscribable m where
    type SubModelID m :: *
    subscribeModelId :: m -> SubModelID m

-- the possible messages/actions on the data model of that channel
data Subscribable m => SubMessage m = SMNewInstance m
                                    | SMNewInstances [m]
                                    | SMDelInstance (SubModelID m)
                                    | SMDelInstances [SubModelID m]
                                    | SMUpdateInstance m

-- handle after subscribing to a channel.
data Channel m = Channel {
    channelName        :: String,
    channelUnsubscribe :: IO ()
    }

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
data Remote a = Remote MethodName [JSON]
#else
-- Server Monad is just a wrapper over IO
newtype Server a = Server { runServerM :: IO a }
                 deriving (Functor, Applicative, Monad, MonadIO)

-- remote values are not interested on the server side either
data Remote a = RemoteDummy
#endif

(<.>) :: ToJSON a => Remote (a -> b) -> a -> Remote b
#if defined(ghcjs_HOST_OS)
(Remote name args) <.> arg = Remote name (toJSON arg : args)
#else
_ <.> _ = RemoteDummy
#endif

-- convert a Remotable value to a Remote
remote :: Remotable a => MethodName -> a -> App (Remote a)
remote = remoteWithMode MethodSync

asyncRemote :: Remotable a => MethodName -> a -> App (Remote a)
asyncRemote = remoteWithMode MethodAsync

remoteWithMode :: Remotable a => MethodMode -> MethodName -> a -> App (Remote a)
#if defined(ghcjs_HOST_OS)
-- client side, just remember the name in the Remote value
remoteWithMode _ n _ = return (Remote n [])
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
type DispatchCenter = M.Map Nonce (MVar JSON)
data ClientState = ClientState {
    csClientId      :: UUID,
    csNonce         :: TVar Nonce,
    csDispCenter    :: TVar DispatchCenter,
    csWebSocket     :: TVar WebSocket,
    subscribeRemote :: Remote (JSON -> Server JSON),
    publishRemote   :: Remote (JSON -> Server ())
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
        liftIO $ forkIO $ pingServer wsTVar
        sendMsg newWs

newResult :: (Monad m, MonadIO m) => Client e m (Nonce, MVar JSON)
newResult = do
    (ClientState uid mNonce mvarDispCenter ws _ _) <- get
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
    mNonce <- liftIO $ atomically $ newTVar 1
    liftIO $ forkIO (pingServer wsTVar)

    uid <- liftIO UUID.generateUUID

    -- setup the two default remote methods used by the framework
    subR <- asyncRemote "subscribe" subscribeForClient
    pubR <- asyncRemote "publish" publishForClient

    let defState = ClientState uid mNonce mvarDispCenter wsTVar subR pubR
    liftIO $ runStateT (runReaderT c (url, env)) defState
    return AppDone

pingServer wsTVar = do
    ws <- readTVarIO wsTVar
    wsSt <- getReadyState ws
    if wsSt == Connecting || wsSt == OPEN
        then do
        send (encode $ toJSON (0 :: Int, "ping" :: String, [] :: [Int])) ws
        threadDelay 3000000
        pingServer wsTVar
        else return ()

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

-- start the websocket server with db param, file path for static assets and port
onEvent :: TVar Connection -> M.Map MethodName (MethodMode, Method) -> JSON -> Server ()
#if defined(ghcjs_HOST_OS)
onEvent _ _ _ = ServerDummy
#else
-- server side dispatcher of client function calls
onEvent connTVar mapping incoming = do
    let Success (nonce :: Int, identifier :: MethodName, args :: [JSON]) = fromJSON incoming
    unless (nonce == 0 && identifier == "ping") $ do
        let Just (m, f) = M.lookup identifier mapping
            processEvt = do
                result <- f args
                conn <- liftIO $ readTVarIO connTVar
                liftIO $ sendTextData conn $ encode (nonce, result)
        case m of
            MethodSync -> processEvt
            MethodAsync -> liftIO $ void $ forkIO $ runServerM processEvt
#endif


subscribeForClient = undefined
publishForClient = undefined

#if defined(ghcjs_HOST_OS)
-- subscribe on the client side will just call a server side function to setup
-- and return the channel handle
subscribe :: Subscribable m => ChannelName -> (SubMessage m -> IO ()) -> IO (Channel m)
subscribe name cb = undefined
#else
subscribe = undefined
#endif

publish :: Subscribable m => SubMessage m -> Channel m -> IO ()
publish = undefined


#if defined(ghcjs_HOST_OS)
websocketServer = undefined
#else
websocketServer remoteMapping pendingConn = do
    conn <- acceptRequestWith pendingConn (AcceptRequest (Just "GHCJS.App") [])
    connTVar <- liftIO $ atomically $ newTVar conn
    websocketHandler remoteMapping connTVar
    -- fork a new thread to send 'ping' control messages to the client every 3 seconds
    forkPingThread conn 3

websocketHandler remoteMapping connTVar = do
    conn <- readTVarIO connTVar
    msg <- receiveData conn
    let Just (m :: JSON) = decode msg
    runServerM $ onEvent connTVar remoteMapping m
    websocketHandler remoteMapping connTVar
#endif

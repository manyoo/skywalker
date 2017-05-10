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

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Map (Map)
import qualified Data.Map as M

import Skywalker.UUID (UUID)
import qualified Skywalker.UUID as UUID

-- import the different library for JSON
#if defined(ghcjs_HOST_OS)
import JavaScript.JSON.Types
import JavaScript.JSON.Types.Class
import JavaScript.JSON.Types.Internal
import JavaScript.JSON.Types.Instances
import JavaScript.Web.XMLHttpRequest
import qualified JavaScript.Web.MessageEvent as ME

import Data.IORef
import Data.JSString hiding (reverse)

import Skywalker.EventSource
-- a dummy websocket connection used only on server side
data Connection

#else
import Control.Exception (SomeException, handle)

import Control.Concurrent.Chan
import Data.Aeson
import Data.Text
import qualified Data.UUID as UUID
import Skywalker.RestServer

import Network.Wai
import Network.Wai.EventSource

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
type RemoteMethod = [JSON] -> Server JSON

-- specify whether the remote method is execuated in a sync, async or subscription based way
data MethodMode = MethodSync
                | MethodAsync
                | MethodSubscribe
                deriving Eq

-- the state stored in the App monad, it is a map of all the defined remote functions
type AppState = M.Map MethodName (MethodMode, RemoteMethod)

-- the top-level App monad for the whole app
newtype App a = App { unApp :: StateT AppState IO a }
              deriving (Functor, Applicative, Monad, MonadIO, MonadState AppState)

-- run the top-level App monad and return an IO action. This should be used at the begining
-- of the whole application
runApp :: App AppDone -> IO ()
runApp = void . flip runStateT M.empty . unApp

-- define a value that be used in remote functions
class Remotable a where
    mkRemote :: a -> RemoteMethod

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

type SSEChannelMap = Map ClientID (Chan ServerEvent)

data ServerEnv = ServerEnv {
    seClientId       :: Maybe ClientID,
    seCurrentNonce   :: Maybe Int,
    seSSEChanMapTVar :: Maybe (TVar SSEChannelMap)
    }

instance Default ServerEnv where
    def = ServerEnv Nothing Nothing Nothing

type Server a = ReaderT ServerEnv IO a

runServerM e = flip runReaderT e

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
    csDispCenter :: TVar DispatchCenter
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
    cid <- ceClientId <$> ask
    nonce <- nextNonce

    json <- liftIO $ xhrJSON nonce identifier cid args

    let Success (nonce :: Int, result :: JSON) = fromJSON json
    return $ fromResult $ fromJSON result


xhrJSON nonce identifier cid args = do
    let dat = encode $ toJSON (nonce, identifier, cid, reverse args)
        
        req = Request { reqMethod          = POST,
                        reqURI             = "/swapi/swremote",
                        reqLogin           = Nothing,
                        reqHeaders         = [],
                        reqWithCredentials = False,
                        reqData            = StringData dat
                      }
    -- send the actual request and wait for the result
    jsonResp <- fmap parseJSONString <$> xhr req
    let (Just json) = contents jsonResp
    return json

#else
onServer _ = ClientDummy
#endif

subscribeOnServer :: (FromJSON a, ToJSON a, Monad m, MonadIO m) => Remote (Server a) -> (a -> IO ()) -> Client e m ()
#if defined (ghcjs_HOST_OS)
subscribeOnServer (Remote identifier mode args) cb = do
    (nonce, mv) <- newResult mode
    cid         <- ceClientId <$> ask
    n           <- csNonce    <$> get

    -- send the actual request and wait for the result
    liftIO $ xhrJSON nonce identifier cid args

    liftIO $ forever $ do
        res <- (fromResult . fromJSON) <$> takeMVar mv
        cb res


newResult :: (Monad m, MonadIO m) => MethodMode -> Client e m (Nonce, MVar JSON)
newResult mode = do
    (ClientState mNonce mvarDispCenter) <- get
    mv <- liftIO newEmptyMVar
    nonce <- liftIO $ readTVarIO mNonce
    liftIO $ atomically $ do
        modifyTVar' mvarDispCenter (\m -> M.insert nonce (mode, mv) m)
        writeTVar mNonce (nonce + 1)
    return (nonce, mv)

nextNonce :: (Monad m, MonadIO m) => Client t m Nonce
nextNonce = do
    (ClientState mNonce _) <- get
    nonce <- liftIO $ readTVarIO mNonce
    liftIO $ atomically $ writeTVar mNonce (nonce + 1)
    return nonce

#else
subscribeOnServer _ _ = ClientDummy
#endif

runClient :: URL -> e -> Client e IO a -> App AppDone
#if defined(ghcjs_HOST_OS)
runClient url env c = liftIO $ do
    mvarDispCenter <- atomically $ newTVar M.empty
    mNonce <- atomically $ newTVar 1
    cid <- UUID.generateUUID

    es <- mkEventSource $ pack $ "/swsse?clientId=" ++ show cid
    onMessage (onServerMessage mvarDispCenter) es

    let defState = ClientState mNonce mvarDispCenter
    runStateT (runReaderT c (ClientEnv url cid env)) defState

    return AppDone

onServerMessage mvarDispCenter e = do
    let ME.StringData msg = ME.getData e
        res = fromJSON $ parseJSONString msg
    case res of
        Success (nonce :: Int, result :: JSON) -> do
            m <- readTVarIO mvarDispCenter
            let (mode, mv) = m M.! nonce
            putMVar mv result
        Error e -> print e

-- import the javascript JSON.parse function to transform a js string to a JSON Value type
foreign import javascript unsafe "JSON['parse']($1)" parseJSONString :: JSString -> JSON
#else
runClient _ _ _ = return AppDone
#endif

onEvent :: M.Map MethodName (MethodMode, RemoteMethod) -> JSON -> Server LBS.ByteString
#if defined(ghcjs_HOST_OS)
onEvent _ _ = ServerDummy
#else
-- server side dispatcher of client function calls
onEvent mapping incoming = do
    let Success (nonce :: Int, identifier :: MethodName, cid :: UUID, args :: [JSON]) = fromJSON incoming
    e <- ask
    let Just (m, f) = M.lookup identifier mapping
        processEvt = f args >>= (return . respBuilder nonce)
        processSub = void $ f args
        newEnv = e { seClientId     = Just cid,
                     seCurrentNonce = Just nonce
                   }
    case m of
        MethodSync -> processEvt
        MethodAsync -> processEvt
        MethodSubscribe -> liftIO $ runServerM newEnv processSub >> return (respBuilder nonce ([] :: [Int]))
#endif

#if defined(ghcjs_HOST_OS)
skywalkerServer = undefined
#else
skywalkerServer remoteMapping sseChannelMapTVar backupApp =
    restOr "swapi" (buildRest [("swremote", swRestApp remoteMapping sseChannelMapTVar)]) $
        sseApp "swsse" sseChannelMapTVar backupApp    

swRestApp remoteMapping sseChannelMapTVar req = do
    msg <- lazyRequestBody req
    let Just (m :: JSON) = decode msg
    runServerM (def {seSSEChanMapTVar = Just sseChannelMapTVar }) $ onEvent remoteMapping m

buildSSEChannelMapTVar :: IO (TVar SSEChannelMap)
buildSSEChannelMapTVar = newTVarIO M.empty

-- build Server Sent Event Application
sseApp :: Text -> TVar SSEChannelMap -> Application -> Application
sseApp endPoint sseChannelMapTVar backupApp req sendResponses = do
    let p = safeHead $ pathInfo req
        safeHead []    = Nothing
        safeHead (a:_) = Just a
        clientIdM = join $ lookup "clientId" $ queryString req
    if p == Just endPoint && isJust clientIdM
        then do
            let cid = fromJust $ join $ (UUID.fromByteString . LBS.fromStrict) <$> clientIdM
            c <- newChan
            atomically $ modifyTVar sseChannelMapTVar (M.alter (const $ Just c) cid)
            eventSourceAppChan c req sendResponses
        else backupApp req sendResponses

respBuilder :: ToJSON a => Int -> a -> LBS.ByteString
respBuilder nonce res = encode (nonce, res)
#endif

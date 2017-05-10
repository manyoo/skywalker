{-# LANGUAGE CPP, TypeFamilies, FlexibleContexts, UndecidableInstances, OverloadedStrings #-}
module Skywalker.PubSub
    (Subscribable(..), SubMessage(..), getSubModelId,
#if !defined(ghcjs_HOST_OS)
    ChannelBuilder(..), buildChannel
#endif
    ) where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Default

import Control.Concurrent.STM
import Control.Concurrent.Chan

import Skywalker.App
import Skywalker.JSON

#if !defined(ghcjs_HOST_OS)
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Trans

import Network.Wai.EventSource
import Data.Binary.Builder
import Data.Maybe

#endif

-- Subscribable defines the class for all data models that can be used in
-- a channel
class Subscribable m where
    type SubModelID m :: *
    subscribeModelId :: m -> SubModelID m

-- the possible messages/actions on the data model of that channel
data Subscribable m => SubMessage m = SMNewInstance m
                                    | SMNewInstances [m]
                                    | SMDelInstance m
                                    | SMDelInstances (SubModelID m)
                                    | SMUpdateInstance m
                                    | SMUpdateInstances [m]
                                    | SMDummy -- just used for return of cbSubscribe
                                              -- because it's not actually used

instance (Subscribable m, Show m) => Show (SubMessage m) where
    show (SMNewInstance m)      = "SMNewInstance " ++ show m
    show (SMNewInstances ms)    = "SMNewInstances " ++ show ms
    show (SMDelInstance m)      = "SMDelInstance " ++ show m
    show (SMDelInstances i)     = "SMDelInstances"
    show (SMUpdateInstance m)   = "SMUpdateInstance " ++ show m
    show (SMUpdateInstances ms) = "SMUpdateInstances " ++ show ms
    show SMDummy                = "SMDummy"

instance (Subscribable m, ToJSON m, ToJSON (SubModelID m)) => ToJSON (SubMessage m) where
    toJSON (SMNewInstance m)      = object ["cmd" .= ("NewInstance" :: String), "value" .= m]
    toJSON (SMNewInstances ms)    = object ["cmd" .= ("NewInstances" :: String), "value" .= ms]
    toJSON (SMDelInstance m)      = object ["cmd" .= ("DelInstance" :: String), "value" .= m]
    toJSON (SMDelInstances i)     = object ["cmd" .= ("DelInstances" :: String), "value" .= i]
    toJSON (SMUpdateInstance m)   = object ["cmd" .= ("UpdateInstance" :: String), "value" .= m]
    toJSON (SMUpdateInstances ms) = object ["cmd" .= ("UpdateInstances" :: String), "value" .= ms]
    toJSON SMDummy                = object ["cmd" .= ("Dummy" :: String), "value" .= ("" :: String)]

instance (Subscribable m, FromJSON m, FromJSON (SubModelID m)) => FromJSON (SubMessage m) where
    parseJSON v = do
        let o = toObject v
        c <- o .: "cmd"
        let parseValue "NewInstance"     = SMNewInstance    <$> o .: "value"
            parseValue "NewInstances"    = SMNewInstances   <$> o .: "value"
            parseValue "DelInstance"     = SMDelInstance    <$> o .: "value"
            parseValue "DelInstances"    = SMDelInstances   <$> o .: "value"
            parseValue "UpdateInstance"  = SMUpdateInstance <$> o .: "value"
            parseValue "UpdateInstances" = SMUpdateInstances <$> o .: "value"
            parseValue "Dummy"           = return SMDummy
        parseValue $ jsonString c

safeHead []    = Nothing
safeHead (x:_) = Just x

getSubModelId :: Subscribable m => SubMessage m -> Maybe (SubModelID m)
getSubModelId (SMNewInstance m)      = Just $ subscribeModelId m
getSubModelId (SMNewInstances ms)    = subscribeModelId <$> safeHead ms
getSubModelId (SMDelInstance m)      = Just $ subscribeModelId m
getSubModelId (SMDelInstances i)     = Just i
getSubModelId (SMUpdateInstance m)   = Just $ subscribeModelId m
getSubModelId (SMUpdateInstances ms) = subscribeModelId <$> safeHead ms

#if !defined(ghcjs_HOST_OS)
-- the three remote methods to be exposed to the client side
data ChannelBuilder m = ChannelBuilder {
    cbSubscribe       :: SubModelID m  -> Server (SubMessage m),
    cbPublish         :: SubMessage m  -> Server (),
    cbUnsubscribe     :: SubModelID m  -> Server (),
    cbServerSubscribe :: (SubMessage m -> Server ()) -> IO ()
    }

-- data structures used for managing the subscription channels and clients
data ClientSubscription m = ClientSubscription {
    csClientId   :: ClientID,
    csSubModelId :: SubModelID m,
    csNonce      :: Int
    }

-- data type used for managing the server side subscriptions
newtype ServerSubscription m = ServerSubscription {
    ssCallback :: SubMessage m -> Server ()
    }

-- this will store all subscribers for one channel
data ChannelSubscribers m = ChannelSubscribers {
    csClientSubscribers :: Map (ClientID, SubModelID m) (ClientSubscription m),
    csServerSubscriber  :: Maybe (ServerSubscription m)
    }

instance Default (ChannelSubscribers m) where
    def = ChannelSubscribers Map.empty Nothing

addClientSubscriber :: (Subscribable m, Ord (SubModelID m)) => ChannelSubscribers m -> ClientSubscription m -> ChannelSubscribers m
addClientSubscriber ch cs = ch { csClientSubscribers = newMap }
    where m = csClientSubscribers ch
          k = (csClientId cs, csSubModelId cs)

          newMap = case Map.lookup k m of
                        Just _ -> m
                        Nothing -> Map.insert k cs m

delClientSubscriber :: (Subscribable m, Ord (SubModelID m)) => ChannelSubscribers m -> ClientID -> SubModelID m -> ChannelSubscribers m
delClientSubscriber ch cid sid = ch { csClientSubscribers = newMap }
    where m = csClientSubscribers ch
          k = (cid, sid)
          newMap = Map.delete k m

delClientSubscribers :: (Subscribable m, Ord (SubModelID m)) => ChannelSubscribers m -> [ClientSubscription m] -> ChannelSubscribers m
delClientSubscribers ch css = ch { csClientSubscribers = newMap }
    where m = csClientSubscribers ch
          s = Set.fromList $ (\cs -> (csClientId cs, csSubModelId cs)) <$> css
          newMap = Map.filterWithKey (\k _ -> k `Set.notMember` s) m

addServerSubscriber :: Subscribable m => ChannelSubscribers m -> ServerSubscription m -> ChannelSubscribers m
addServerSubscriber ch ss = ch { csServerSubscriber = Just ss }

findSubscribers :: Eq (SubModelID m) => ChannelSubscribers m -> ClientID -> SubModelID m -> [ClientSubscription m]
findSubscribers ch cid sid = Map.elems $ Map.filter (validSubscriber cid sid) $ csClientSubscribers ch

validSubscriber :: Eq (SubModelID m) => ClientID -> SubModelID m -> ClientSubscription m -> Bool
validSubscriber cid sid cs = csClientId cs /= cid && csSubModelId cs == sid

buildChannel :: (Subscribable m, ToJSON m, ToJSON (SubModelID m), Eq (SubModelID m), Ord (SubModelID m)) => IO (ChannelBuilder m)
buildChannel = do
    channelTVar <- atomically $ newTVar def
    let sub   = mkClientSubscribeFunc channelTVar
        pub   = mkClientPublishFunc channelTVar
        unsub = mkClientUnsubscribeFunc channelTVar
        sSub  = mkServerSubscribeFunc channelTVar
    return $ ChannelBuilder sub pub unsub sSub

-- subscribe to a channel on client side
mkClientSubscribeFunc channelTVar sid = do
    clientIdM <- seClientId <$> ask
    nonceM    <- seCurrentNonce <$> ask
    liftIO $ when (isJust clientIdM && isJust nonceM) $ atomically $ do
        let cid    = fromJust clientIdM
            nonce  = fromJust nonceM
        ch <- readTVar channelTVar
        let cs = ClientSubscription cid sid nonce
            newCh = addClientSubscriber ch cs
        writeTVar channelTVar newCh

    return SMDummy

-- subscribe to a channel on server side
mkServerSubscribeFunc channelTVar cb = atomically $ do
    ch <- readTVar channelTVar
    writeTVar channelTVar $ addServerSubscriber ch (ServerSubscription cb)

-- publish message on client side
mkClientPublishFunc channelTVar msg = do
    -- find all valid clients and publish to them
    clientIdM <- seClientId <$> ask
    let sidM = getSubModelId msg
    when (isJust clientIdM && isJust sidM) $ do
        ch <- liftIO $ atomically $ readTVar channelTVar
        let css = findSubscribers ch (fromJust clientIdM) (fromJust sidM)
        resLst <- mapM (publishToClient msg) css
        let csToDel = snd <$> filter (not . fst) resLst
            newCh = delClientSubscribers ch csToDel
        liftIO $ atomically $ writeTVar channelTVar newCh
        
        -- if there's server subscribers, call them
        let serverSubM = csServerSubscriber ch
        mapM_ (\ss -> (ssCallback ss) msg) serverSubM

-- unsubscribe a channel on client side
mkClientUnsubscribeFunc channelTVar sid = do
    clientIdM <- seClientId <$> ask
    liftIO $ when (isJust clientIdM) $ atomically $ do
        ch <- readTVar channelTVar
        let newCh = delClientSubscriber ch (fromJust clientIdM) sid
        writeTVar channelTVar newCh

publishToClient :: (Subscribable m, ToJSON m, ToJSON (SubModelID m)) => SubMessage m -> ClientSubscription m -> Server (Bool, ClientSubscription m)
publishToClient msg cs = do
    let nonce = csNonce cs
        cid   = csClientId cs
    sseChanMapTVarM <- seSSEChanMapTVar <$> ask
    case sseChanMapTVarM of
        Just sseChanMapTVar -> do
            m <- liftIO $ readTVarIO sseChanMapTVar
            let cm = Map.lookup cid m
                msgStr = respBuilder nonce msg
            liftIO $ mapM_ (\c -> writeChan c $ ServerEvent Nothing Nothing [fromLazyByteString msgStr]) cm
            return (True, cs)
        Nothing -> return (False, cs)
#endif

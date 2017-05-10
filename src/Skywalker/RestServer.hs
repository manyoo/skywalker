{-# LANGUAGE OverloadedStrings #-}
module Skywalker.RestServer (RestAPI, restOr, buildRest) where

import Data.Text hiding (tail)
import Data.ByteString.Lazy hiding (tail)

import Network.Wai
import Network.HTTP.Types.Status

safeHead []    = Nothing
safeHead (a:_) = Just a

restOr :: Text -> Application -> Application -> Application
restOr endPoint restApp backupApp req send_response = do
    let p = safeHead $ pathInfo req
    if p == Just endPoint
        then restApp req send_response
        else backupApp req send_response


type RestAPI = (Text, Request -> IO ByteString)

buildRest :: [RestAPI] -> Application
buildRest apis req send_response = do
    let pm = safeHead (tail $ pathInfo req) >>= flip lookup apis
    case pm of
        Nothing -> send_response $ responseBuilder status404 [] "invalid API call"
        Just p  -> p req >>= (send_response . responseLBS status200 [])

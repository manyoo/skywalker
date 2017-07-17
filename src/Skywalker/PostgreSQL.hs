{-# LANGUAGE CPP #-}
module Skywalker.PostgreSQL (
#if defined(ghcjs_HOST_OS) || defined(client)
  Connection,
  connectPostgreSQL,
  close
#else
  module Database.PostgreSQL.Simple
#endif
  ) where

#if defined(ghcjs_HOST_OS) || defined(client)
data Connection
connectPostgreSQL = undefined
close = undefined
#else
import Database.PostgreSQL.Simple
#endif

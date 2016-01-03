{-# LANGUAGE CPP #-}
module Skywalker.PostgreSQL (
#if defined(ghcjs_HOST_OS)
  Connection,
  connectPostgreSQL,
  close
#else
  module Database.PostgreSQL.Simple
#endif
  ) where

#if defined(ghcjs_HOST_OS)
data Connection
connectPostgreSQL = undefined
close = undefined
#else
import Database.PostgreSQL.Simple
#endif

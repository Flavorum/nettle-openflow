{-# LANGUAGE TypeOperators, MultiParamTypeClasses, FunctionalDependencies #-}
{-# LANGUAGE BangPatterns #-}

-- | This module provides data structures for Ethernet frames
-- as well as parsers and unparsers for Ethernet frames. 
module Nettle.Ethernet.EthernetFrame ( 
  
  -- * Data types
  EthernetFrame(..)
  , EthernetBody(..)
  , EthernetHeader(..)
  , EthernetTypeCode  
  , ethTypeVLAN
  , ethTypeIP
  , ethTypeARP
  , ethTypeLLDP
  , ethTypeIPv6
  , ethType8021X
  , ethTypePaneDP
  , typeEth2Cutoff
  , VLANPriority
  , VLANID
  , eth_ip_packet
  , eth_ip_tcp_packet
  , eth_ip_udp_packet
  , foldEthernetFrame
  , foldEthernetBody

    -- * Parsers and unparsers 
  , getEthernetFrame
  , getEthHeader
  , getEthHeader2
  , putEthHeader
  , putEthFrame
    
    -- * ARP frames    
  , arpQuery
  , arpReply
    
  ) where

import Nettle.Ethernet.EthernetAddress
import Nettle.IPv4.IPPacket
import Nettle.IPv4.IPAddress
import Nettle.Ethernet.AddressResolutionProtocol
import qualified Data.ByteString as B
import Data.Binary
import Data.Binary.Get
import Data.Word
import Data.Bits
import Control.Monad
import Control.Monad.Error
import Data.HList
import qualified Data.Binary.Strict.Get as Strict
import qualified Nettle.OpenFlow.StrictPut as Strict
import qualified Data.Binary.Get as Binary

-- | An Ethernet frame is either an IP packet, an ARP packet, or an uninterpreted @ByteString@.
-- Based on http://en.wikipedia.org/wiki/File:Ethernet_Type_II_Frame_format.svg
type EthernetFrame = EthernetHeader :*: EthernetBody :*: HNil
                     

data EthernetBody  = IPInEthernet !IPPacket
                   | ARPInEthernet !ARPPacket
                   | PaneDPInEthernet Word64 Word16
                   | UninterpretedEthernetBody !B.ByteString
                   deriving (Show,Eq)

foldEthernetFrame :: (EthernetHeader -> EthernetBody -> a) -> EthernetFrame -> a
foldEthernetFrame f (HCons h (HCons b HNil)) = f h b

foldEthernetBody :: (IPPacket -> a) -> (ARPPacket -> a) -> (B.ByteString -> a) -> EthernetBody -> a
foldEthernetBody f g h (IPInEthernet x) = f x
foldEthernetBody f g h (ARPInEthernet x) = g x
foldEthernetBody f g h (UninterpretedEthernetBody x) = h x

withFrame :: HList l 
             => (EthernetBody -> Maybe l) 
             -> EthernetFrame 
             -> Maybe (EthernetHeader :*: l)
withFrame f frame = foldEthernetFrame (\h b -> fmap (hCons h) (f b)) frame

fromIPPacket :: EthernetBody -> Maybe IPPacket
fromIPPacket = foldEthernetBody Just (const Nothing) (const Nothing)

fromARPPacket :: EthernetBody -> Maybe (ARPPacket :*: HNil)
fromARPPacket = foldEthernetBody (const Nothing) (\x -> Just (hCons x HNil)) (const Nothing)

eth_ip_packet :: EthernetFrame -> Maybe (EthernetHeader :*: IPPacket)
eth_ip_packet = withFrame fromIPPacket

eth_ip_tcp_packet :: EthernetFrame -> Maybe (EthernetHeader :*: IPHeader :*: TCPHeader :*: HNil)
eth_ip_tcp_packet = withFrame $ fromIPPacket >=> withIPPacket fromTCPPacket

eth_ip_udp_packet :: EthernetFrame -> Maybe (EthernetHeader :*: IPHeader :*: UDPHeader :*: B.ByteString :*: HNil)
eth_ip_udp_packet = withFrame $ fromIPPacket >=> withIPPacket fromUDPPacket

eth_arp_packet :: EthernetFrame -> Maybe (EthernetHeader :*: ARPPacket :*: HNil)
eth_arp_packet = withFrame fromARPPacket


data EthernetHeader   = EthernetHeader { destMACAddress   :: !EthernetAddress, 
                                         sourceMACAddress :: !EthernetAddress, 
                                         typeCode         :: !EthernetTypeCode }
                      | Ethernet8021Q {  destMACAddress           :: !EthernetAddress, 
                                         sourceMACAddress         :: !EthernetAddress, 
                                         typeCode                 :: !EthernetTypeCode, 
                                         priorityCodePoint        :: !VLANPriority, 
                                         canonicalFormatIndicator :: !Bool, 
                                         vlanId                   :: !VLANID }
                        deriving (Read,Show,Eq)


type VLANPriority     = Word8

-- | Ethernet type code, determines the type of payload carried by an Ethernet frame.
type EthernetTypeCode = Word16

type VLANID           = Word16


arpQuery :: EthernetAddress   -- ^ source hardware address
            -> IPAddress      -- ^ source IP address
            -> IPAddress      -- ^ target IP address
            -> EthernetFrame
arpQuery sha spa tpa = hCons hdr (hCons (ARPInEthernet ( body)) hNil)
  where hdr = EthernetHeader { destMACAddress    = broadcastAddress
                             , sourceMACAddress  = sha
                             , typeCode          = ethTypeARP 
                             } 
        body = ARPQuery (ARPQueryPacket { querySenderEthernetAddress = sha
                                        , querySenderIPAddress = spa
                                        , queryTargetIPAddress = tpa
                                        } 
                        )


arpReply :: EthernetAddress     -- ^ source hardware address
            -> IPAddress        -- ^ source IP address
            -> EthernetAddress  -- ^ target hardware address
            -> IPAddress        -- ^ target IP address
            -> EthernetFrame
arpReply sha spa tha tpa = hCons hdr (hCons (ARPInEthernet ( body)) hNil)
  where hdr = EthernetHeader { destMACAddress   = tha
                             , sourceMACAddress = sha
                             , typeCode         = ethTypeARP 
                             } 
        body = ARPReply (ARPReplyPacket { replySenderEthernetAddress = sha
                                        , replySenderIPAddress       = spa
                                        , replyTargetEthernetAddress = tha
                                        , replyTargetIPAddress       = tpa
                                        } 
                        )


-- | Parser for Ethernet frames.
getEthernetFrame :: Strict.Get EthernetFrame
getEthernetFrame = do 
  hdr <- {-# SCC "getEthHeader" #-} getEthHeader
  -- r <- Strict.remaining
  case typeCode hdr of
    v | v == ethTypeIP -> do
      ipPacket <- getIPPacket
      return $ hCons hdr (hCons (IPInEthernet ipPacket) hNil)            
    v | v == ethTypeARP -> do
      mArpPacket <- getARPPacket
      case mArpPacket of
        Just arpPacket -> return $ 
          hCons hdr (hCons (ARPInEthernet arpPacket) hNil)
        Nothing -> error "cannot decode arp packet"
    v | v == ethTypePaneDP -> do
      switchID <- Strict.getWord64be
      portID <- Strict.getWord16be
      return (hCons hdr (hCons (PaneDPInEthernet switchID portID) hNil))
    v | v == ethTypeIPv6 -> do
      bs <- Strict.getByteString ipv6HeaderLen -- let's pretend options don't exist...
      return (hCons hdr (hCons (UninterpretedEthernetBody bs) hNil))
    v | v == ethType8021X -> do
      bs <- Strict.getByteString eth8021xHeaderLen -- let's ignore the body for now...
      return (hCons hdr (hCons (UninterpretedEthernetBody bs) hNil))
    otherwise ->  error $ "unknown ethernet type code: " ++ show (typeCode hdr)

-- | Parser for Ethernet headers.
getEthHeader2 :: Binary.Get EthernetHeader
getEthHeader2 = do 
  dstAddr <- getEthernetAddress2
  srcAddr <- getEthernetAddress2
  tcode   <- Binary.getWord16be
  if tcode < typeEth2Cutoff 
    then error "don't know how to parse this kind of ethernet frame"
    else if (tcode == ethTypeVLAN) 
         then do x <- Binary.getWord16be
                 etherType <- Binary.getWord16be
                 let pcp = fromIntegral (shiftR x 13)
                 let cfi = testBit x 12
                 let vid = clearBits x [12,13,14,15]
                 return (Ethernet8021Q dstAddr srcAddr etherType pcp cfi vid)
         else return (EthernetHeader dstAddr srcAddr tcode)

getEthHeader :: Strict.Get EthernetHeader
getEthHeader = do 
  dstAddr <- getEthernetAddress
  srcAddr <- getEthernetAddress
  tcode   <- Strict.getWord16be
  if tcode >= typeEth2Cutoff 
    then if (tcode /= ethTypeVLAN) 
         then return (EthernetHeader dstAddr srcAddr tcode)
         else do x <- Strict.getWord16be
                 etherType <- Strict.getWord16be
                 let pcp = fromIntegral (shiftR x 13)
                 let cfi = testBit x 12
                 let vid = clearBits x [12,13,14,15]
                 return (Ethernet8021Q dstAddr srcAddr etherType pcp cfi vid)
    else Strict.zero
{-# INLINE getEthHeader #-}


-- | Unparser for Ethernet headers.
putEthHeader :: EthernetHeader -> Strict.Put 
putEthHeader (EthernetHeader dstAddr srcAddr tcode) =  
    do putEthernetAddress dstAddr
       putEthernetAddress srcAddr
       Strict.putWord16be tcode
putEthHeader (Ethernet8021Q dstAddr srcAddr tcode pcp cfi vid) = 
    do putEthernetAddress dstAddr
       putEthernetAddress srcAddr
       Strict.putWord16be ethTypeVLAN
       Strict.putWord16be x
       Strict.putWord16be tcode
    where x = let y = shiftL (fromIntegral pcp :: Word16) 13
                  y' = if cfi then setBit y 12 else y
              in y' + fromIntegral vid


putEthFrame :: EthernetFrame -> Strict.Put
putEthFrame (HCons hdr (HCons body HNil)) =  do
  putEthHeader hdr
  case body of
    IPInEthernet ipPacket -> error "put method NYI for IP packets"
    ARPInEthernet arpPacket -> error "put method NYI for ARP packets"
    UninterpretedEthernetBody bs -> Strict.putByteString bs
    PaneDPInEthernet switchID portID -> do
      Strict.putWord64be switchID
      Strict.putWord16be portID


-- Best source for list: https://en.wikipedia.org/wiki/EtherType
ethTypeIP, ethTypeARP, ethTypeLLDP, ethTypeVLAN, ethTypeIPv6, ethType8021X, typeEth2Cutoff :: EthernetTypeCode
ethTypeIP           = 0x0800
ethTypeARP          = 0x0806
ethTypeLLDP         = 0x88CC
ethTypeVLAN         = 0x8100
ethTypeIPv6			= 0x86DD
ethType8021X        = 0x888E
typeEth2Cutoff = 0x0600

ethTypePaneDP :: EthernetTypeCode
ethTypePaneDP = 0x0777

ipv6HeaderLen = 40
eth8021xHeaderLen = 4

clearBits :: Bits a => a -> [Int] -> a 
clearBits = foldl clearBit


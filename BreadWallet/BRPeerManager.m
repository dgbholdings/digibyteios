//
//  BRPeerManager.m
//  BreadWallet
//
//  Created by Aaron Voisine on 10/6/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BRPeerManager.h"
#import "BRPeer.h"
#import "BRPeerEntity.h"
#import "BRBloomFilter.h"
#import "BRKeySequence.h"
#import "BRTransaction.h"
#import "BRTransactionEntity.h"
#import "BRMerkleBlock.h"
#import "BRMerkleBlockEntity.h"
#import "BRWalletManager.h"
#import "NSString+Base58.h"
#import "NSData+DigiByte.h"
#import "NSManagedObject+Sugar.h"
#import <netdb.h>

#if ! PEER_LOGGING
#define NSLog(...)
#endif

#define FIXED_PEERS          @"FixedPeers"
// Sitt 2015-12-09 YOLO
// #define PROTOCOL_TIMEOUT     20.0
#define PROTOCOL_TIMEOUT 15.0
#define MAX_CONNECT_FAILURES 20 // notify user of network problems after this many connect failures in a row
#define CHECKPOINT_COUNT     (sizeof(checkpoint_array)/sizeof(*checkpoint_array))

// Sitt 2015-11-09 #define GENESIS_BLOCK_HASH   (*(UInt256 *)@(checkpoint_array[0].hash).hexToData.reverse.bytes)
#define GENESIS_BLOCK_HASH  (*(UInt256 *) @"7497ea1b465eb39f1c8f507bc877078fe016d6fcb6dfad3a64c98dcc6e1e8496".hexToData.reverse.bytes)
#define SYNC_STARTHEIGHT_KEY @"SYNC_STARTHEIGHT"

// blockchain checkpoints - these are also used as starting points for partial chain downloads, so they need to be at
// difficulty transition boundaries in order to verify the block difficulty at the immediately following transition
static const struct { uint32_t height; char *hash; uint32_t timestamp; uint32_t target; } checkpoint_array[] = {
//   {     0, "852c475c605e1f20bbe60219c811abaeef08bf0d4ff87eef59200fd7a7567fa7", 1413145109, 0x1b336ce6 },
    // Sitt 2016-02-18 Use Checkpoint from the First day of digiwallet fork (from breadWallet)
    {  145000, "f8d650dda836d5e3809b928b8523f050891c3bb9fa2c201bb04824a8a2fe7df6", 1409596362, 0x1c01f271},
    { 1800000, "72f46e1fff56518dce7e540b407260ea827cb1c4652f24eb1d1917f54b95d65a", 1454769372, 0x1c021355},
    { 2149922, "557846763a5f1eb3205d175724bd26ba7123c17c49eaaadf20b67c7e20e3118a", 1460001303, 0x1c012a26},
    { 4444444, "0000000000000114de2ba1462056d2a9bd9ccfbd406cd2dfedaaef2c12910659", 1494132592, 0x1a01152f}

};

/* Sitt 2015-11-09
static const char *dns_seeds[] = {
    "seed.breadwallet.com", "seed.bitcoin.sipa.be.", "dnsseed.bluematt.me.", "dnsseed.bitcoin.dashjr.org.",
    "seed.bitcoinstats.com.", "seed.bitnodes.io."
};*/
static const char *dns_seeds[] = {
    "seed.digibyte.co", "seed2.hashdragon.com", "dgb.cryptoservices.net"
    "52.183.103.9", "138.91.245.174", "13.82.55.134", "66.228.56.115"
};

@interface BRPeerManager ()

@property (nonatomic, strong) NSMutableOrderedSet *peers;
@property (nonatomic, strong) NSMutableSet *connectedPeers, *misbehavinPeers, *nonFpTx;
@property (nonatomic, strong) BRPeer *downloadPeer;
@property (nonatomic, assign) uint32_t tweak, syncStartHeight, filterUpdateHeight;
@property (nonatomic, strong) BRBloomFilter *bloomFilter;
@property (nonatomic, assign) double fpRate;
@property (nonatomic, assign) NSUInteger taskId, connectFailures, misbehavinCount;
@property (nonatomic, assign) NSTimeInterval earliestKeyTime, lastRelayTime;
@property (nonatomic, strong) NSMutableDictionary *blocks, *orphans, *checkpoints, *txRelays, *txRequests;
@property (nonatomic, strong) NSMutableDictionary *publishedTx, *publishedCallback;
@property (nonatomic, strong) BRMerkleBlock *lastBlock, *lastOrphan;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic, strong) id backgroundObserver, seedObserver;

@end

@implementation BRPeerManager

+ (instancetype)sharedInstance
{
    static id singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        singleton = [self new];
    });
    
    return singleton;
}

- (instancetype)init
{
    if (! (self = [super init])) return nil;

    self.earliestKeyTime = [BRWalletManager sharedInstance].seedCreationTime;
    self.connectedPeers = [NSMutableSet set];
    self.misbehavinPeers = [NSMutableSet set];
    self.nonFpTx = [NSMutableSet set];
    self.tweak = arc4random();
    self.taskId = UIBackgroundTaskInvalid;
    self.q = dispatch_queue_create("peermanager", NULL);
    self.orphans = [NSMutableDictionary dictionary];
    self.txRelays = [NSMutableDictionary dictionary];
    self.txRequests = [NSMutableDictionary dictionary];
    self.publishedTx = [NSMutableDictionary dictionary];
    self.publishedCallback = [NSMutableDictionary dictionary];

    self.backgroundObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            [self savePeers];
            [self saveBlocks];

            if (self.taskId == UIBackgroundTaskInvalid) {
                self.misbehavinCount = 0;
                [self.connectedPeers makeObjectsPerformSelector:@selector(disconnect)];
            }
        }];

    self.seedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletManagerSeedChangedNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.earliestKeyTime = [BRWalletManager sharedInstance].seedCreationTime;
            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:SYNC_STARTHEIGHT_KEY];
            [self.txRelays removeAllObjects];
            [self.publishedTx removeAllObjects];
            [self.publishedCallback removeAllObjects];
            [BRMerkleBlockEntity deleteObjects:[BRMerkleBlockEntity allObjects]];
            [BRMerkleBlockEntity saveContext];
            _blocks = nil;
            _bloomFilter = nil;
            _lastBlock = nil;
            [self.connectedPeers makeObjectsPerformSelector:@selector(disconnect)];
        }];

    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.backgroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.backgroundObserver];
    if (self.seedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.seedObserver];
}

- (NSMutableOrderedSet *)peers
{
    if (_peers.count >= PEER_MAX_CONNECTIONS) return _peers;

    @synchronized(self) {
        if (_peers.count >= PEER_MAX_CONNECTIONS) return _peers;
        _peers = [NSMutableOrderedSet orderedSet];

        [[BRPeerEntity context] performBlockAndWait:^{
            for (BRPeerEntity *e in [BRPeerEntity allObjects]) {
                @autoreleasepool {
                    if (e.misbehavin == 0) [_peers addObject:[e peer]];
                    else [self.misbehavinPeers addObject:[e peer]];
                }
            }
        }];

        [self sortPeers];

        // DNS peer discovery
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSMutableArray *peers = [NSMutableArray arrayWithObject:[NSMutableArray array]];

        if (_peers.count < PEER_MAX_CONNECTIONS ||
            ((BRPeer *)_peers[PEER_MAX_CONNECTIONS - 1]).timestamp + 3*24*60*60 < now) {
            while (peers.count < sizeof(dns_seeds)/sizeof(*dns_seeds)) [peers addObject:[NSMutableArray array]];
        }
        
        if (peers.count > 0) {
            dispatch_apply(peers.count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t i) {
                NSString *servname = @(BITCOIN_STANDARD_PORT).stringValue;
                struct addrinfo hints = { 0, AF_UNSPEC, SOCK_STREAM, 0, 0, 0, NULL, NULL }, *servinfo, *p;
                UInt128 addr = { .u32 = { 0, 0, CFSwapInt32HostToBig(0xffff), 0 } };

                NSLog(@"DNS lookup %s", dns_seeds[i]);
                
                if (getaddrinfo(dns_seeds[i], servname.UTF8String, &hints, &servinfo) == 0) {
                    for (p = servinfo; p != NULL; p = p->ai_next) {
                        if (p->ai_family == AF_INET) {
                            addr.u64[0] = 0;
                            addr.u32[2] = CFSwapInt32HostToBig(0xffff);
                            addr.u32[3] = ((struct sockaddr_in *)p->ai_addr)->sin_addr.s_addr;
                        }
//                        else if (p->ai_family == AF_INET6) {
//                            addr = *(UInt128 *)&((struct sockaddr_in6 *)p->ai_addr)->sin6_addr;
//                        }
                        else continue;
                        
                        uint16_t port = CFSwapInt16BigToHost(((struct sockaddr_in *)p->ai_addr)->sin_port);
                        NSTimeInterval age = 3*24*60*60 + arc4random_uniform(4*24*60*60); // add between 3 and 7 days
                    
                        [peers[i] addObject:[[BRPeer alloc] initWithAddress:addr port:port
                                             timestamp:(i > 0 ? now - age : now) services:SERVICES_NODE_NETWORK]];
                    }

                    freeaddrinfo(servinfo);
                }
            });
            
            for (NSArray *a in peers) [_peers addObjectsFromArray:a];

#if BITCOIN_TESTNET
            [self sortPeers];
            return _peers;
#endif
            // if DNS peer discovery fails, fall back on a hard coded list of peers (list taken from satoshi client)
            if (_peers.count < PEER_MAX_CONNECTIONS) {
                UInt128 addr = { .u32 = { 0, 0, CFSwapInt32HostToBig(0xffff), 0 } };
            
                for (NSNumber *address in [NSArray arrayWithContentsOfFile:[[NSBundle mainBundle]
                                           pathForResource:FIXED_PEERS ofType:@"plist"]]) {
                    // give hard coded peers a timestamp between 7 and 14 days ago
                    addr.u32[3] = CFSwapInt32HostToBig(address.unsignedIntValue);
                    [_peers addObject:[[BRPeer alloc] initWithAddress:addr port:BITCOIN_STANDARD_PORT
                     timestamp:now - (7*24*60*60 + arc4random_uniform(7*24*60*60)) services:SERVICES_NODE_NETWORK]];
                }
            }
            
            [self sortPeers];
        }

        return _peers;
    }
}

- (NSMutableDictionary *)blocks
{
    if (_blocks.count > 0) return _blocks;
    
    [[BRMerkleBlockEntity context] performBlockAndWait:^{
        if (_blocks.count > 0) return;
        _blocks = [NSMutableDictionary dictionary];
        self.checkpoints = [NSMutableDictionary dictionary];
        
        for (int i = ([BRWalletManager sharedInstance].isNewWallet == false)? 0 : CHECKPOINT_COUNT-1; i < CHECKPOINT_COUNT; i++) { // add checkpoints to the block collection
            UInt256 hash = *(UInt256 *)@(checkpoint_array[i].hash).hexToData.reverse.bytes;
            
            _blocks[uint256_obj(hash)] = [[BRMerkleBlock alloc] initWithBlockHash:hash version:1 prevBlock:UINT256_ZERO
                                                                       merkleRoot:UINT256_ZERO timestamp:checkpoint_array[i].timestamp
                                                                           target:checkpoint_array[i].target nonce:0 totalTransactions:0 hashes:nil
                                                                            flags:nil height:checkpoint_array[i].height];
            self.checkpoints[@(checkpoint_array[i].height)] = uint256_obj(hash);
        }
        
        for (BRMerkleBlockEntity *e in [BRMerkleBlockEntity allObjects]) {
            @autoreleasepool {
                BRMerkleBlock *b = e.merkleBlock;
                if (b) _blocks[uint256_obj(b.blockHash)] = b;
            }
        };
    }];
    
    return _blocks;
}

// this is used as part of a getblocks or getheaders request
- (NSArray *)blockLocatorArray
{
    // append 10 most recent block hashes, decending, then continue appending, doubling the step back each time,
    // finishing with the genesis block (top, -1, -2, -3, -4, -5, -6, -7, -8, -9, -11, -15, -23, -39, -71, -135, ..., 0)
    NSMutableArray *locators = [NSMutableArray array];
    int32_t step = 1, start = 0;
    BRMerkleBlock *b = self.lastBlock;

    while (b && b.height > 0) {
        [locators addObject:uint256_obj(b.blockHash)];
        if (++start >= 10) step *= 2;

        for (int32_t i = 0; b && i < step; i++) {
            b = self.blocks[uint256_obj(b.prevBlock)];
        }
    }

    [locators addObject:uint256_obj(GENESIS_BLOCK_HASH)];
    return locators;
}

- (BRMerkleBlock *)lastBlock
{
    if (! _lastBlock) {
        NSFetchRequest *req = [BRMerkleBlockEntity fetchRequest];
        
        req.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:NO]];
        req.predicate = [NSPredicate predicateWithFormat:@"height >= 0 && height != %d", BLOCK_UNKNOWN_HEIGHT];
        req.fetchLimit = 1;
        _lastBlock = [[BRMerkleBlockEntity fetchObjects:req].lastObject merkleBlock];
        
        // if we don't have any blocks yet, use the latest checkpoint that's at least a week older than earliestKeyTime
        for (int i = CHECKPOINT_COUNT - 1; ! _lastBlock && i >= 0; i--) {
            if (i == 0 || checkpoint_array[i].timestamp + 7*24*60*60 < self.earliestKeyTime + NSTimeIntervalSince1970) {
                UInt256 hash = *(UInt256 *)@(checkpoint_array[i].hash).hexToData.reverse.bytes;
                
                _lastBlock = [[BRMerkleBlock alloc] initWithBlockHash:hash version:1 prevBlock:UINT256_ZERO
                                                           merkleRoot:UINT256_ZERO timestamp:checkpoint_array[i].timestamp
                                                               target:checkpoint_array[i].target nonce:0 totalTransactions:0 hashes:nil flags:nil
                                                               height:checkpoint_array[i].height];
            }
        }
        
        if (_lastBlock.height > _estimatedBlockHeight) _estimatedBlockHeight = _lastBlock.height;
    }
    
    return _lastBlock;
}

- (uint32_t)lastBlockHeight
{
    return self.lastBlock.height;
}

- (double)syncProgress
{
    if (! self.downloadPeer && self.syncStartHeight == 0) return 0.0;
    if (self.lastBlockHeight == self.syncStartHeight) return 0.05;
    if (self.lastBlockHeight >= self.estimatedBlockHeight) return 1.0;
    return 0.1 + 0.9*(self.lastBlockHeight - self.syncStartHeight)/(self.estimatedBlockHeight - self.syncStartHeight);
}

// number of connected peers
- (NSUInteger)peerCount
{
    NSUInteger count = 0;

    for (BRPeer *peer in self.connectedPeers) {
        if (peer.status == BRPeerStatusConnected) count++;
    }

    return count;
}

- (BRBloomFilter *)bloomFilter
{
    if (_bloomFilter) return _bloomFilter;

    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    // every time a new wallet address is added, the bloom filter has to be rebuilt, and each address is only used for
    // one transaction, so here we generate some spare addresses to avoid rebuilding the filter each time a wallet
    // transaction is encountered during the blockchain download
    [manager.wallet addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL + 100 internal:NO];
    [manager.wallet addressesWithGapLimit:SEQUENCE_GAP_LIMIT_INTERNAL + 100 internal:YES];

    [self.orphans removeAllObjects]; // clear out orphans that may have been received on an old filter
    self.lastOrphan = nil;
    self.filterUpdateHeight = self.lastBlockHeight;
    self.fpRate = BLOOM_REDUCED_FALSEPOSITIVE_RATE;

    NSUInteger elemCount = manager.wallet.addresses.count + manager.wallet.unspentOutputs.count;
    BRBloomFilter *filter = [[BRBloomFilter alloc] initWithFalsePositiveRate:self.fpRate
                             forElementCount:elemCount + 100 tweak:self.tweak flags:BLOOM_UPDATE_ALL];

    for (NSString *address in manager.wallet.addresses) {// add addresses to watch for tx receiveing money to the wallet
        NSData *hash = address.addressToHash160;

        if (hash && ! [filter containsData:hash]) [filter insertData:hash];
    }

    for (NSValue *utxo in manager.wallet.unspentOutputs) { // add UTXOs to watch for tx sending money from the wallet
        BRUTXO o;
        NSData *d;
        
        [utxo getValue:&o];
        d = [NSData dataWithBytes:&o length:sizeof(o)];
        if (! [filter containsData:d]) [filter insertData:d];
    }

    // TODO: XXXX if already synced, recursively add inputs of unconfirmed receives
    _bloomFilter = filter;
    return _bloomFilter;
}

- (void)connect
{
    dispatch_async(self.q, ^{
        if ([BRWalletManager sharedInstance].noWallet) return; // check to make sure the wallet has been created
        if (self.connectFailures >= MAX_CONNECT_FAILURES) self.connectFailures = 0; // this attempt is a manual retry
    
        if (self.syncProgress < 1.0) {

            // Sitt 2016-02-18 Use Checkpoint from the First day of digiwallet fork (from breadWallet)
            if (self.syncStartHeight == 145000) {
                self.syncStartHeight = (uint32_t)[[NSUserDefaults standardUserDefaults]
                                                  integerForKey:SYNC_STARTHEIGHT_KEY];
            }
            
            // Sitt 2016-02-18 Use Checkpoint from the First day of digiwallet fork (from breadWallet)
            if (self.syncStartHeight == 145000) {
                self.syncStartHeight = self.lastBlockHeight;
                [[NSUserDefaults standardUserDefaults] setInteger:self.syncStartHeight forKey:SYNC_STARTHEIGHT_KEY];
            }

            if (self.taskId == UIBackgroundTaskInvalid) { // start a background task for the chain sync
                self.taskId =
                    [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                        dispatch_async(self.q, ^{
                            [self saveBlocks];
                        });

                        [self syncStopped];
                    }];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncStartedNotification
                 object:nil];
            });
        }

        [self.connectedPeers minusSet:[self.connectedPeers objectsPassingTest:^BOOL(id obj, BOOL *stop) {
            return ([obj status] == BRPeerStatusDisconnected) ? YES : NO;
        }]];

        if (self.connectedPeers.count >= PEER_MAX_CONNECTIONS) return; //already connected to PEER_MAX_CONNECTIONS peers

        NSMutableOrderedSet *peers = [NSMutableOrderedSet orderedSetWithOrderedSet:self.peers];

        if (peers.count > 100) [peers removeObjectsInRange:NSMakeRange(100, peers.count - 100)];

        while (peers.count > 0 && self.connectedPeers.count < PEER_MAX_CONNECTIONS) {
            // pick a random peer biased towards peers with more recent timestamps
            BRPeer *p = peers[(NSUInteger)(pow(arc4random_uniform((uint32_t)peers.count), 2)/peers.count)];

            if (p && ! [self.connectedPeers containsObject:p]) {
                [p setDelegate:self queue:self.q];
                p.earliestKeyTime = self.earliestKeyTime;
                [self.connectedPeers addObject:p];
                [p connect];
            }

            [peers removeObject:p];
        }

        [self bloomFilter]; // initialize wallet and bloomFilter while connecting

        if (self.connectedPeers.count == 0) {
            [self syncStopped];

            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"BreadWallet" code:1
                                  userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"no peers found", nil)}];

                [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFailedNotification
                 object:nil userInfo:@{@"error":error}];
            });
        }
    });
}

// rescans blocks and transactions after earliestKeyTime, a new random download peer is also selected due to the
// possibility that a malicious node might lie by omitting transactions that match the bloom filter
- (void)rescan
{
    if (! self.connected) return;

    dispatch_async(self.q, ^{
        _lastBlock = nil;

        // start the chain download from the most recent checkpoint that's at least a week older than earliestKeyTime
        for (int i = CHECKPOINT_COUNT - 1; ! _lastBlock && i >= 0; i--) {
            if (i == 0 || checkpoint_array[i].timestamp + 7*24*60*60 < self.earliestKeyTime + NSTimeIntervalSince1970) {
                _lastBlock = self.blocks[@(checkpoint_array[i].hash).hexToData.reverse];
            }
        }

        if (self.downloadPeer) { // disconnect the current download peer so a new random one will be selected
            [self.peers removeObject:self.downloadPeer];
            [self.downloadPeer disconnect];
        }

        self.syncStartHeight = self.lastBlockHeight;
        [[NSUserDefaults standardUserDefaults] setInteger:self.syncStartHeight forKey:SYNC_STARTHEIGHT_KEY];
        [self connect];
    });
}

// adds transaction to list of tx to be published, along with any unconfirmed inputs
- (void)addTransactionToPublishList:(BRTransaction *)transaction
{
    if (transaction.blockHeight == TX_UNCONFIRMED) {
        self.publishedTx[uint256_obj(transaction.txHash)] = transaction;
    
        for (NSValue *hash in transaction.inputHashes) {
            UInt256 h = UINT256_ZERO;
            
            [hash getValue:&h];
            [self addTransactionToPublishList:[[BRWalletManager sharedInstance].wallet transactionForHash:h]];
        }
    }
}

- (void)publishTransaction:(BRTransaction *)transaction completion:(void (^)(NSError *error))completion
{
    if (! transaction.isSigned) {
        if (completion) {
            completion([NSError errorWithDomain:@"BreadWallet" code:401 userInfo:@{NSLocalizedDescriptionKey:
                        NSLocalizedString(@"bitcoin transaction not signed", nil)}]);
        }
        
        return;
    }
    else if (! self.connected && self.connectFailures >= MAX_CONNECT_FAILURES) {
        if (completion) {
            completion([NSError errorWithDomain:@"BreadWallet" code:-1009 userInfo:@{NSLocalizedDescriptionKey:
                        NSLocalizedString(@"not connected to the bitcoin network", nil)}]);
        }
        
        return;
    }

    NSMutableSet *peers = [NSMutableSet setWithSet:self.connectedPeers];
    NSValue *hash = uint256_obj(transaction.txHash);
    
    [self addTransactionToPublishList:transaction];
    if (completion) self.publishedCallback[hash] = completion;

    NSArray *txHashes = self.publishedTx.allKeys;

    // instead of publishing to all peers, leave out the download peer to see if the tx propogates and gets relayed back
    // TODO: XXX connect to a random peer with an empty or fake bloom filter just for publishing
    if (self.peerCount > 1) [peers removeObject:self.downloadPeer];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self performSelector:@selector(txTimeout:) withObject:hash afterDelay:PROTOCOL_TIMEOUT];

        for (BRPeer *p in peers) {
            [p sendInvMessageWithTxHashes:txHashes];
            [p sendPingMessageWithPongHandler:^(BOOL success) {
                if (! success) return;

                for (NSValue *h in txHashes) {
                    if ([self.txRelays[h] containsObject:p] || [self.txRequests[h] containsObject:p]) continue;
                    if (! self.txRequests[h]) self.txRequests[h] = [NSMutableSet set];
                    [self.txRequests[h] addObject:p];
                    [p sendGetdataMessageWithTxHashes:@[h] andBlockHashes:nil];
                }
            }];
        }
    });
}

// number of connected peers that have relayed the transaction
- (NSUInteger)relayCountForTransaction:(UInt256)txHash
{
    return [self.txRelays[uint256_obj(txHash)] count];
}

// seconds since reference date, 00:00:00 01/01/01 GMT
// NOTE: this is only accurate for the last two weeks worth of blocks, other timestamps are estimated from checkpoints
- (NSTimeInterval)timestampForBlockHeight:(uint32_t)blockHeight
{
    if (blockHeight == TX_UNCONFIRMED) return (self.lastBlock.timestamp - NSTimeIntervalSince1970) + 10*60; //next block

    if (blockHeight >= self.lastBlockHeight) { // future block, assume 10 minutes per block after last block
        return (self.lastBlock.timestamp - NSTimeIntervalSince1970) + (blockHeight - self.lastBlockHeight)*10*60;
    }

    if (_blocks.count > 0) {
        if (blockHeight >= self.lastBlockHeight - BLOCK_DIFFICULTY_INTERVAL*2) { // recent block we have the header for
            BRMerkleBlock *block = self.lastBlock;

            while (block && block.height > blockHeight) block = self.blocks[uint256_obj(block.prevBlock)];
            if (block) return block.timestamp - NSTimeIntervalSince1970;
        }
    }
    else [[BRMerkleBlockEntity context] performBlock:^{ [self blocks]; }];

    uint32_t h = self.lastBlockHeight, t = self.lastBlock.timestamp;

    for (int i = CHECKPOINT_COUNT - 1; i >= 0; i--) { // estimate from checkpoints
        if (checkpoint_array[i].height <= blockHeight) {
            t = checkpoint_array[i].timestamp + (t - checkpoint_array[i].timestamp)*
                (blockHeight - checkpoint_array[i].height)/(h - checkpoint_array[i].height);
            return t - NSTimeIntervalSince1970;
        }

        h = checkpoint_array[i].height;
        t = checkpoint_array[i].timestamp;
    }

    return checkpoint_array[0].timestamp - NSTimeIntervalSince1970;
}

- (void)setBlockHeight:(int32_t)height andTimestamp:(NSTimeInterval)timestamp forTxHashes:(NSArray *)txHashes
{
    [[BRWalletManager sharedInstance].wallet setBlockHeight:height andTimestamp:timestamp forTxHashes:txHashes];
    
    if (height != TX_UNCONFIRMED) { // remove confirmed tx from publish list and relay counts
        [self.publishedTx removeObjectsForKeys:txHashes];
        [self.publishedCallback removeObjectsForKeys:txHashes];
        [self.txRelays removeObjectsForKeys:txHashes];
    }
}

- (void)txTimeout:(NSValue *)txHash
{
    void (^callback)(NSError *error) = self.publishedCallback[txHash];

    [self.publishedTx removeObjectForKey:txHash];
    [self.publishedCallback removeObjectForKey:txHash];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:txHash];

    if (callback) {
        callback([NSError errorWithDomain:@"BreadWallet" code:BITCOIN_TIMEOUT_CODE userInfo:@{NSLocalizedDescriptionKey:
                  NSLocalizedString(@"transaction canceled, network timeout", nil)}]);
    }
}

- (void)syncTimeout
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - self.lastRelayTime < PROTOCOL_TIMEOUT) { // the download peer relayed something in time, so restart timer
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
        [self performSelector:@selector(syncTimeout) withObject:nil
         afterDelay:PROTOCOL_TIMEOUT - (now - self.lastRelayTime)];
        return;
    }

    dispatch_async(self.q, ^{
        if (! self.downloadPeer) return;
        NSLog(@"%@:%d chain sync timed out", self.downloadPeer.host, self.downloadPeer.port);
        [self.peers removeObject:self.downloadPeer];
        [self.downloadPeer disconnect];
    });
}

- (void)syncStopped
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];

        if (self.taskId != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
            self.taskId = UIBackgroundTaskInvalid;
        }
    });
}

- (void)loadMempools
{
    NSArray *txHashes = self.publishedTx.allKeys;
    
    for (BRPeer *p in self.connectedPeers) { // after syncing, load filters and get mempools from other peers
        if (p != self.downloadPeer || self.fpRate > BLOOM_REDUCED_FALSEPOSITIVE_RATE*5.0) {
            [p sendFilterloadMessage:self.bloomFilter.data];
        }
        
        [p sendInvMessageWithTxHashes:txHashes]; // publish unconfirmed tx
        [p sendPingMessageWithPongHandler:^(BOOL success) {
            if (success) {
                [p sendMempoolMessage];
                [p sendPingMessageWithPongHandler:^(BOOL success) {
                    if (success) {
                        p.synced = YES;
                        [p sendGetaddrMessage]; // request a list of other bitcoin peers
                        [self removeUnrelayedTransactions];
                    }
                    
                    if (p == self.downloadPeer) {
                        [self syncStopped];

                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter]
                             postNotificationName:BRPeerManagerSyncFinishedNotification object:nil];
                        });
                    }
                }];
            }
            else if (p == self.downloadPeer) {
                [self syncStopped];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                     postNotificationName:BRPeerManagerSyncFinishedNotification object:nil];
                });
            }
        }];
    }
    
    // Sitt 2016-02-18 Use Checkpoint from the First day of digiwallet fork (from breadWallet)
    if ([BRWalletManager sharedInstance].isNewWallet == false) self.syncStartHeight = 2149922;
    else self.syncStartHeight = 145000;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
    });
}

// unconfirmed transactions that aren't in the mempools of any of connected peers have likely dropped off the network
- (void)removeUnrelayedTransactions
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    BOOL rescan = NO, notify = NO;
    NSValue *hash;
    UInt256 h;

    // don't remove transactions until we're connected to PEER_MAX_CONNECTION peers
    if (self.connectedPeers.count < PEER_MAX_CONNECTIONS) return;
    
    for (BRPeer *p in self.connectedPeers) { // don't remove tx until all peers have finished relaying their mempools
        if (! p.synced) return;
    }

    for (BRTransaction *tx in manager.wallet.recentTransactions) {
        if (tx.blockHeight != TX_UNCONFIRMED) break;
        hash = uint256_obj(tx.txHash);

        if ([self.txRelays[hash] count] == 0 && [self.txRequests[hash] count] == 0) {
            // if this is for a transaction we sent, and it wasn't already known to be invalid, notify user of failure
            if (! rescan && [manager.wallet amountSentByTransaction:tx] > 0 && [manager.wallet transactionIsValid:tx]) {
                rescan = notify = YES;
                
                for (NSValue *hash in tx.inputHashes) { // only recommend a rescan if all inputs are confirmed
                    [hash getValue:&h];
                    if ([manager.wallet transactionForHash:h].blockHeight != TX_UNCONFIRMED) continue;
                    rescan = NO;
                    break;
                }
            }
            
            [manager.wallet removeTransaction:tx.txHash];
        }
        else if ([self.txRelays[hash] count] < PEER_MAX_CONNECTIONS) {
            // set timestamp 0 to mark as unverified
            [self setBlockHeight:TX_UNCONFIRMED andTimestamp:0 forTxHashes:@[hash]];
        }
    }
    
    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rescan) {
                [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"transaction rejected", nil)
                  message:NSLocalizedString(@"Your wallet may be out of sync.\n"
                                            "This can often be fixed by rescanning the blockchain.", nil) delegate:self
                  cancelButtonTitle:NSLocalizedString(@"cancel", nil)
                  otherButtonTitles:NSLocalizedString(@"rescan", nil), nil] show];
            }
            else {
                [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"transaction rejected", nil)
                  message:nil delegate:nil cancelButtonTitle:NSLocalizedString(@"ok", nil) otherButtonTitles:nil] show];
            }
        });
    }
}

- (void)updateFilter
{
    if (self.downloadPeer.needsFilterUpdate) return;
    self.downloadPeer.needsFilterUpdate = YES;
    NSLog(@"filter update needed, waiting for pong");
    
    [self.downloadPeer sendPingMessageWithPongHandler:^(BOOL success) { // wait for pong so we include already sent tx
        if (! success) return;
        NSLog(@"updating filter with newly created wallet addresses");
        _bloomFilter = nil;

        if (self.lastBlockHeight < self.estimatedBlockHeight) { // if we're syncing, only update download peer
            [self.downloadPeer sendFilterloadMessage:self.bloomFilter.data];
            [self.downloadPeer sendPingMessageWithPongHandler:^(BOOL success) { // wait for pong so filter is loaded
                if (! success) return;
                self.downloadPeer.needsFilterUpdate = NO;
                [self.downloadPeer rerequestBlocksFrom:self.lastBlock.blockHash];
                [self.downloadPeer sendPingMessageWithPongHandler:^(BOOL success) {
                    if (! success || self.downloadPeer.needsFilterUpdate) return;
                    [self.downloadPeer sendGetblocksMessageWithLocators:[self blockLocatorArray]
                     andHashStop:UINT256_ZERO];
                }];
            }];
        }
        else {
            for (BRPeer *p in self.connectedPeers) {
                [p sendFilterloadMessage:self.bloomFilter.data];
                [p sendPingMessageWithPongHandler:^(BOOL success) { // wait for pong so we know filter is loaded
                    if (! success) return;
                    p.needsFilterUpdate = NO;
                    [p sendMempoolMessage];
                }];
            }
        }
    }];
}

- (void)peerMisbehavin:(BRPeer *)peer
{
    peer.misbehavin++;
    [self.peers removeObject:peer];
    [self.misbehavinPeers addObject:peer];

    if (++self.misbehavinCount >= 10) { // clear out stored peers so we get a fresh list from DNS for next connect
        self.misbehavinCount = 0;
        [self.misbehavinPeers removeAllObjects];
        [BRPeerEntity deleteObjects:[BRPeerEntity allObjects]];
        _peers = nil;
    }
    
    [peer disconnect];
    [self connect];
}

- (void)sortPeers
{
    [_peers sortUsingComparator:^NSComparisonResult(BRPeer *p1, BRPeer *p2) {
        if (p1.timestamp > p2.timestamp) return NSOrderedAscending;
        if (p1.timestamp < p2.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)savePeers
{
    NSMutableSet *peers = [[self.peers.set setByAddingObjectsFromSet:self.misbehavinPeers] mutableCopy];
    NSMutableSet *addrs = [NSMutableSet set];

    for (BRPeer *p in peers) {
        if (p.address.u64[0] != 0 || p.address.u32[2] != CFSwapInt32HostToBig(0xffff)) continue; //skip IPv6 for now
        [addrs addObject:@(CFSwapInt32BigToHost(p.address.u32[3]))];
    }

    [[BRPeerEntity context] performBlock:^{
        [BRPeerEntity deleteObjects:[BRPeerEntity objectsMatching:@"! (address in %@)", addrs]]; // remove deleted peers

        for (BRPeerEntity *e in [BRPeerEntity objectsMatching:@"address in %@", addrs]) { // update existing peers
            @autoreleasepool {
                BRPeer *p = [peers member:[e peer]];
                
                if (p) {
                    e.timestamp = p.timestamp;
                    e.services = p.services;
                    e.misbehavin = p.misbehavin;
                    [peers removeObject:p];
                }
                else [e deleteObject];
            }
        }

        for (BRPeer *p in peers) {
            @autoreleasepool {
                [[BRPeerEntity managedObject] setAttributesFromPeer:p]; // add new peers
            }
        }
    }];
}

- (void)saveBlocks
{
    NSMutableDictionary *blocks = [NSMutableDictionary dictionary];
    BRMerkleBlock *b = self.lastBlock;

    while (b) {
        blocks[[NSData dataWithBytes:b.blockHash.u8 length:sizeof(UInt256)]] = b;
        b = self.blocks[uint256_obj(b.prevBlock)];
    }

    [[BRMerkleBlockEntity context] performBlock:^{
        [BRMerkleBlockEntity deleteObjects:[BRMerkleBlockEntity objectsMatching:@"! (blockHash in %@)",
                                            blocks.allKeys]];

        for (BRMerkleBlockEntity *e in [BRMerkleBlockEntity objectsMatching:@"blockHash in %@", blocks.allKeys]) {
            @autoreleasepool {
                [e setAttributesFromBlock:blocks[e.blockHash]];
                [blocks removeObjectForKey:e.blockHash];
            }
        }

        for (BRMerkleBlock *b in blocks.allValues) {
            @autoreleasepool {
                [[BRMerkleBlockEntity managedObject] setAttributesFromBlock:b];
            }
        }
        
        [BRMerkleBlockEntity saveContext];
    }];
}

#pragma mark - BRPeerDelegate

- (void)peerConnected:(BRPeer *)peer
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (peer.timestamp > now + 2*60*60 || peer.timestamp < now - 2*60*60) peer.timestamp = now; //timestamp sanity check
    self.connectFailures = 0;
    NSLog(@"%@:%d connected with lastblock %d", peer.host, peer.port, peer.lastblock);
    
    // drop peers that don't carry full blocks, or aren't synced yet
    // TODO: XXXX does this work with 0.11 pruned nodes?
    if (! (peer.services & SERVICES_NODE_NETWORK) || peer.lastblock + 10 < self.lastBlockHeight) {
        [peer disconnect];
        return;
    }

    for (BRTransaction *tx in manager.wallet.recentTransactions) {
        if (tx.blockHeight != TX_UNCONFIRMED) break;

        if ([manager.wallet amountSentByTransaction:tx] > 0 && [manager.wallet transactionIsValid:tx]) {
            [self addTransactionToPublishList:tx]; // add unconfirmed valid send tx to mempool
        }
    }

    if (self.connected && (self.estimatedBlockHeight >= peer.lastblock || self.lastBlockHeight >= peer.lastblock)) {
        if (self.lastBlockHeight < self.estimatedBlockHeight) return; // don't load bloom filter yet if we're syncing
        [peer sendFilterloadMessage:self.bloomFilter.data];
        [peer sendInvMessageWithTxHashes:self.publishedTx.allKeys]; // publish unconfirmed tx
        [peer sendPingMessageWithPongHandler:^(BOOL success) {
            [peer sendMempoolMessage];
            [peer sendPingMessageWithPongHandler:^(BOOL success) {
                if (! success) return;
                peer.synced = YES;
                [peer sendGetaddrMessage]; // request a list of other bitcoin peers
                [self removeUnrelayedTransactions];
            }];
        }];

        return; // we're already connected to a download peer
    }

    // select the peer with the lowest ping time to download the chain from if we're behind
    // BUG: XXX a malicious peer can report a higher lastblock to make us select them as the download peer, if two
    // peers agree on lastblock, use one of them instead
    for (BRPeer *p in self.connectedPeers) {
        if ((p.pingTime < peer.pingTime && p.lastblock >= peer.lastblock) || p.lastblock > peer.lastblock) peer = p;
    }

    [self.downloadPeer disconnect];
    self.downloadPeer = peer;
    _connected = YES;
    _estimatedBlockHeight = peer.lastblock;
    _bloomFilter = nil; // make sure the bloom filter is updated with any newly generated addresses
    [peer sendFilterloadMessage:self.bloomFilter.data];
    peer.currentBlockHeight = self.lastBlockHeight;
    [peer sendInvMessageWithTxHashes:self.publishedTx.allKeys]; // publish pending transactions
    
    if (self.lastBlockHeight < peer.lastblock) { // start blockchain sync
        self.lastRelayTime = 0;

        dispatch_async(dispatch_get_main_queue(), ^{ // setup a timer to detect if the sync stalls
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncTimeout) object:nil];
            [self performSelector:@selector(syncTimeout) withObject:nil afterDelay:PROTOCOL_TIMEOUT];

            dispatch_async(self.q, ^{
                // request just block headers up to a week before earliestKeyTime, and then merkleblocks after that
                // BUG: XXX headers can timeout on slow connections (each message is over 160k)
                if (self.lastBlock.timestamp + 7*24*60*60 >= self.earliestKeyTime + NSTimeIntervalSince1970) {
                    [peer sendGetblocksMessageWithLocators:[self blockLocatorArray] andHashStop:UINT256_ZERO];
                }
                else [peer sendGetheadersMessageWithLocators:[self blockLocatorArray] andHashStop:UINT256_ZERO];
            });
        });
    }
    else { // we're already synced
        self.syncStartHeight = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:SYNC_STARTHEIGHT_KEY];
        [self loadMempools];
    }
}

- (void)peer:(BRPeer *)peer disconnectedWithError:(NSError *)error
{
    NSLog(@"%@:%d disconnected%@%@", peer.host, peer.port, (error ? @", " : @""), (error ? error : @""));
    
    if ([error.domain isEqual:@"BreadWallet"] && error.code != BITCOIN_TIMEOUT_CODE) {
        [self peerMisbehavin:peer]; // if it's protocol error other than timeout, the peer isn't following the rules
    }
    else if (error) { // timeout or some non-protocol related network error
        [self.peers removeObject:peer];
        self.connectFailures++;
    }

    for (NSValue *txHash in self.txRelays.allKeys) {
        [self.txRelays[txHash] removeObject:peer];
    }

    if ([self.downloadPeer isEqual:peer]) { // download peer disconnected
        _connected = NO;
        self.downloadPeer = nil;
        if (self.connectFailures > MAX_CONNECT_FAILURES) self.connectFailures = MAX_CONNECT_FAILURES;
    }

    if (! self.connected && self.connectFailures == MAX_CONNECT_FAILURES) {
        [self syncStopped];
        
        // clear out stored peers so we get a fresh list from DNS on next connect attempt
        [self.misbehavinPeers removeAllObjects];
        [BRPeerEntity deleteObjects:[BRPeerEntity allObjects]];
        _peers = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerSyncFailedNotification
             object:nil userInfo:(error) ? @{@"error":error} : nil];
        });
    }
    else if (self.connectFailures < MAX_CONNECT_FAILURES && (self.taskId != UIBackgroundTaskInvalid ||
             [UIApplication sharedApplication].applicationState != UIApplicationStateBackground)) {
        [self connect]; // try connecting to another peer
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
    });
}

- (void)peer:(BRPeer *)peer relayedPeers:(NSArray *)peers
{
    NSLog(@"%@:%d relayed %d peer(s)", peer.host, peer.port, (int)peers.count);
    [self.peers addObjectsFromArray:peers];
    [self.peers minusSet:self.misbehavinPeers];
    [self sortPeers];

    // limit total to 2500 peers
    if (self.peers.count > 2500) [self.peers removeObjectsInRange:NSMakeRange(2500, self.peers.count - 2500)];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // remove peers more than 3 hours old, or until there are only 1000 left
    while (self.peers.count > 1000 && ((BRPeer *)self.peers.lastObject).timestamp + 3*60*60 < now) {
        [self.peers removeObject:self.peers.lastObject];
    }

    if (peers.count > 1 && peers.count < 1000) [self savePeers]; // peer relaying is complete when we receive <1000
}

- (void)peer:(BRPeer *)peer relayedTransaction:(BRTransaction *)transaction
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSValue *hash = uint256_obj(transaction.txHash);
    BOOL syncing = (self.lastBlockHeight < self.estimatedBlockHeight);
    void (^callback)(NSError *error) = self.publishedCallback[hash];

    NSLog(@"%@:%d relayed transaction %@", peer.host, peer.port, hash);

    transaction.timestamp = [NSDate timeIntervalSinceReferenceDate];
    if (syncing && ! [manager.wallet containsTransaction:transaction]) return;
    
//    if (! syncing) {
//        NSMutableArray *txHashes = [NSMutableArray arrayWithCapacity:transaction.inputHashes.count];
//        
//        for (NSValue *hash in transaction.inputHashes) {
//            UInt256 h = UINT256_ZERO;
//            
//            [hash getValue:&h];
//            if (! [manager.wallet transactionForHash:h]) [txHashes addObject:hash];
//        }
//        
//        if (txHashes.count > 0) [peer sendGetdataMessageWithTxHashes:txHashes andBlockHashes:nil];
//    }
    
    if (! [manager.wallet registerTransaction:transaction]) return;
    if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];

    if ([manager.wallet amountSentByTransaction:transaction] > 0 && [manager.wallet transactionIsValid:transaction]) {
        [self addTransactionToPublishList:transaction]; // add valid send tx to mempool
    }
    
    // keep track of how many peers have or relay a tx, this indicates how likely the tx is to confirm
    if (callback || (! syncing && ! [self.txRelays[hash] containsObject:peer])) {
        if (! self.txRelays[hash]) self.txRelays[hash] = [NSMutableSet set];
        [self.txRelays[hash] addObject:peer];
        if (callback) [self.publishedCallback removeObjectForKey:hash];

        if ([self.txRelays[hash] count] >= PEER_MAX_CONNECTIONS &&
            [manager.wallet transactionForHash:transaction.txHash].blockHeight == TX_UNCONFIRMED) {
            [self setBlockHeight:TX_UNCONFIRMED andTimestamp:[NSDate timeIntervalSinceReferenceDate]
             forTxHashes:@[hash]]; // set timestamp when tx is verified
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:hash];
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
            if (callback) callback(nil);
        });
    }
    
    [self.nonFpTx addObject:hash];
    [self.txRequests[hash] removeObject:peer];
    if (! _bloomFilter) return; // bloom filter is aready being updated

    // the transaction likely consumed one or more wallet addresses, so check that at least the next <gap limit>
    // unused addresses are still matched by the bloom filter
    NSArray *external = [manager.wallet addressesWithGapLimit:SEQUENCE_GAP_LIMIT_EXTERNAL internal:NO],
            *internal = [manager.wallet addressesWithGapLimit:SEQUENCE_GAP_LIMIT_INTERNAL internal:YES];
        
    for (NSString *address in [external arrayByAddingObjectsFromArray:internal]) {
        NSData *hash = address.addressToHash160;

        if (! hash || [_bloomFilter containsData:hash]) continue;
        _bloomFilter = nil; // reset bloom filter so it's recreated with new wallet addresses
        [self updateFilter];
        break;
    }
}

- (void)peer:(BRPeer *)peer hasTransaction:(UInt256)txHash
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSValue *hash = uint256_obj(txHash);
    BOOL syncing = (self.lastBlockHeight < self.estimatedBlockHeight);
    BRTransaction *tx = self.publishedTx[hash];
    void (^callback)(NSError *error) = self.publishedCallback[hash];
    
    NSLog(@"%@:%d has transaction %@", peer.host, peer.port, hash);
    if (! tx) tx = [manager.wallet transactionForHash:txHash];
    if (! tx || (syncing && ! [manager.wallet containsTransaction:tx])) return;
    if (! [manager.wallet registerTransaction:tx]) return;
    if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];
    
    // keep track of how many peers have or relay a tx, this indicates how likely the tx is to confirm
    if (callback || (! syncing && ! [self.txRelays[hash] containsObject:peer])) {
        if (! self.txRelays[hash]) self.txRelays[hash] = [NSMutableSet set];
        [self.txRelays[hash] addObject:peer];
        if (callback) [self.publishedCallback removeObjectForKey:hash];

        if ([self.txRelays[hash] count] >= PEER_MAX_CONNECTIONS &&
            [manager.wallet transactionForHash:txHash].blockHeight == TX_UNCONFIRMED) {
            [self setBlockHeight:TX_UNCONFIRMED andTimestamp:[NSDate timeIntervalSinceReferenceDate]
             forTxHashes:@[hash]]; // set timestamp when tx is verified
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:hash];
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
            if (callback) callback(nil);
        });
    }
    
    [self.nonFpTx addObject:hash];
    [self.txRequests[hash] removeObject:peer];
}

- (void)peer:(BRPeer *)peer rejectedTransaction:(UInt256)txHash withCode:(uint8_t)code
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    BRTransaction *tx = [manager.wallet transactionForHash:txHash];
    NSValue *hash = uint256_obj(txHash);
    
    if ([self.txRelays[hash] containsObject:peer]) {
        [self.txRelays[hash] removeObject:peer];

        if (tx.blockHeight == TX_UNCONFIRMED) { // set timestamp 0 for unverified
            [self setBlockHeight:TX_UNCONFIRMED andTimestamp:0 forTxHashes:@[hash]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
#if DEBUG
            [[[UIAlertView alloc] initWithTitle:@"transaction rejected"
              message:[NSString stringWithFormat:@"rejected by %@:%d with code 0x%x", peer.host, peer.port, code]
              delegate:nil cancelButtonTitle:@"ok" otherButtonTitles:nil] show];
#endif
        });
    }
    
    [self.txRequests[hash] removeObject:peer];
    
    // if we get rejected for any reason other than double-spend, the peer is likely misconfigured
    if (code != REJECT_SPENT && [manager.wallet amountSentByTransaction:tx] > 0) {
        for (hash in tx.inputHashes) { // check that all inputs are confirmed before dropping peer
            UInt256 h = UINT256_ZERO;
            
            [hash getValue:&h];
            if ([manager.wallet transactionForHash:h].blockHeight == TX_UNCONFIRMED) return;
        }

        [self peerMisbehavin:peer];
    }
}

- (void)peer:(BRPeer *)peer relayedBlock:(BRMerkleBlock *)block
{
    // ignore block headers that are newer than one week before earliestKeyTime (headers have 0 totalTransactions)
    if (block.totalTransactions == 0 &&
        block.timestamp + 7*24*60*60 > self.earliestKeyTime + NSTimeIntervalSince1970 + 2*60*60) return;

    NSArray *txHashes = block.txHashes;

    // track the observed bloom filter false positive rate using a low pass filter to smooth out variance
    if (peer == self.downloadPeer && block.totalTransactions > 0) {
        NSMutableSet *fp = [NSMutableSet setWithArray:txHashes];
    
        // 1% low pass filter, also weights each block by total transactions, using 800 tx per block as typical
        [fp minusSet:self.nonFpTx]; // wallet tx are not false-positives
        [self.nonFpTx removeAllObjects];
        self.fpRate = self.fpRate*(1.0 - 0.01*block.totalTransactions/800) + 0.01*fp.count/800;

        // false positive rate sanity check
        if (self.downloadPeer.status == BRPeerStatusConnected && self.fpRate > BLOOM_DEFAULT_FALSEPOSITIVE_RATE*10.0) {
            NSLog(@"%@:%d bloom filter false positive rate %f too high after %d blocks, disconnecting...", peer.host,
                  peer.port, self.fpRate, self.lastBlockHeight + 1 - self.filterUpdateHeight);
            self.tweak = arc4random(); // new random filter tweak in case we matched satoshidice or something
            [self.downloadPeer disconnect];
        }
        else if (self.lastBlockHeight + 500 < peer.lastblock && self.fpRate > BLOOM_REDUCED_FALSEPOSITIVE_RATE*10.0) {
            [self updateFilter]; // rebuild bloom filter when it starts to degrade
        }
    }

    if (! _bloomFilter) { // ingore potentially incomplete blocks when a filter update is pending
        if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];
        return;
    }

    NSValue *blockHash = uint256_obj(block.blockHash), *prevBlock = uint256_obj(block.prevBlock);
    BRMerkleBlock *prev = self.blocks[prevBlock];
    uint32_t transitionTime = 0, txTime = 0;
    UInt256 checkpoint = UINT256_ZERO;
    
    if (! prev) { // block is an orphan
        NSLog(@"%@:%d relayed orphan block %@, previous %@, last block is %@, height %d", peer.host, peer.port,
              blockHash, prevBlock, uint256_obj(self.lastBlock.blockHash), self.lastBlockHeight);

        // ignore orphans older than one week ago
        if (block.timestamp < [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970 - 7*24*60*60) return;

        // call getblocks, unless we already did with the previous block, or we're still downloading the chain
        if (self.lastBlockHeight >= peer.lastblock && ! uint256_eq(self.lastOrphan.blockHash, block.prevBlock)) {
            NSLog(@"%@:%d calling getblocks", peer.host, peer.port);
            [peer sendGetblocksMessageWithLocators:[self blockLocatorArray] andHashStop:UINT256_ZERO];
        }

        self.orphans[prevBlock] = block; // orphans are indexed by prevBlock instead of blockHash
        self.lastOrphan = block;
        return;
    }

    block.height = prev.height + 1;
    txTime = block.timestamp/2 + prev.timestamp/2;

    if ((block.height % BLOCK_DIFFICULTY_INTERVAL) == 0) { // hit a difficulty transition, find previous transition time
        BRMerkleBlock *b = block;

        for (uint32_t i = 0; b && i < BLOCK_DIFFICULTY_INTERVAL; i++) {
            b = self.blocks[uint256_obj(b.prevBlock)];
        }

        [[BRMerkleBlockEntity context] performBlock:^{ // save transition blocks to core data immediately
            @autoreleasepool {
                BRMerkleBlockEntity *e = [BRMerkleBlockEntity objectsMatching:@"blockHash == %@",
                                          [NSData dataWithBytes:b.blockHash.u8 length:sizeof(UInt256)]].lastObject;
        
                if (! e) e = [BRMerkleBlockEntity managedObject];
                [e setAttributesFromBlock:b];
            }
            
            [BRMerkleBlockEntity saveContext]; // persist core data to disk
        }];

        transitionTime = b.timestamp;
        
        while (b) { // free up some memory
            b = self.blocks[uint256_obj(b.prevBlock)];
            if (b) [self.blocks removeObjectForKey:uint256_obj(b.blockHash)];
        }
    }
    // Sitt 2015-12-08 Disable Difficulty Check for syncing
    // verify block difficulty
    /*if (! [block verifyDifficultyFromPreviousBlock:prev andTransitionTime:transitionTime]) {
        NSLog(@"%@:%d relayed block with invalid difficulty target %x, blockHash: %@", peer.host, peer.port,
              block.target, blockHash);
        [self peerMisbehavin:peer];
        return;
    }*/

    [self.checkpoints[@(block.height)] getValue:&checkpoint];
    
    // verify block chain checkpoints
    if (! uint256_is_zero(checkpoint) && ! uint256_eq(block.blockHash, checkpoint)) {
        NSLog(@"%@:%d relayed a block that differs from the checkpoint at height %d, blockHash: %@, expected: %@",
              peer.host, peer.port, block.height, blockHash, self.checkpoints[@(block.height)]);
        [self peerMisbehavin:peer];
        return;
    }
    
    if (uint256_eq(block.prevBlock, self.lastBlock.blockHash)) { // new block extends main chain
        if ((block.height % 500) == 0 || txHashes.count > 0 || block.height > peer.lastblock) {
            NSLog(@"adding block at height: %d, false positive rate: %f", block.height, self.fpRate);
        }

        self.blocks[blockHash] = block;
        self.lastBlock = block;
        [self setBlockHeight:block.height andTimestamp:txTime - NSTimeIntervalSince1970 forTxHashes:txHashes];
        if (peer == self.downloadPeer) self.lastRelayTime = [NSDate timeIntervalSinceReferenceDate];
        self.downloadPeer.currentBlockHeight = block.height;
    }
    else if (self.blocks[blockHash] != nil) { // we already have the block (or at least the header)
        if ((block.height % 500) == 0 || txHashes.count > 0 || block.height > peer.lastblock) {
            NSLog(@"%@:%d relayed existing block at height %d", peer.host, peer.port, block.height);
        }

        self.blocks[blockHash] = block;

        BRMerkleBlock *b = self.lastBlock;

        while (b && b.height > block.height) b = self.blocks[uint256_obj(b.prevBlock)]; // is block in main chain?

        if (uint256_eq(b.blockHash, block.blockHash)) { // if it's not on a fork, set block heights for its transactions
            [self setBlockHeight:block.height andTimestamp:txTime - NSTimeIntervalSince1970 forTxHashes:txHashes];
            if (block.height == self.lastBlockHeight) self.lastBlock = block;
        }
    }
    else { // new block is on a fork
        if (block.height <= checkpoint_array[CHECKPOINT_COUNT - 1].height) { // fork is older than last checkpoint
            NSLog(@"ignoring block on fork older than most recent checkpoint, fork height: %d, blockHash: %@",
                  block.height, blockHash);
            return;
        }

        // special case, if a new block is mined while we're rescanning the chain, mark as orphan til we're caught up
        if (self.lastBlockHeight < peer.lastblock && block.height > self.lastBlockHeight + 1) {
            NSLog(@"marking new block at height %d as orphan until rescan completes", block.height);
            self.orphans[prevBlock] = block;
            self.lastOrphan = block;
            return;
        }

        NSLog(@"chain fork to height %d", block.height);
        self.blocks[blockHash] = block;
        if (block.height <= self.lastBlockHeight) return; // if fork is shorter than main chain, ignore it for now

        NSMutableArray *txHashes = [NSMutableArray array];
        BRMerkleBlock *b = block, *b2 = self.lastBlock;

        while (b && b2 && ! uint256_eq(b.blockHash, b2.blockHash)) { // walk back to where the fork joins the main chain
            b = self.blocks[uint256_obj(b.prevBlock)];
            if (b.height < b2.height) b2 = self.blocks[uint256_obj(b2.prevBlock)];
        }

        NSLog(@"reorganizing chain from height %d, new height is %d", b.height, block.height);

        // mark transactions after the join point as unconfirmed
        for (BRTransaction *tx in [BRWalletManager sharedInstance].wallet.recentTransactions) {
            if (tx.blockHeight <= b.height) break;
            [txHashes addObject:uint256_obj(tx.txHash)];
        }

        [self setBlockHeight:TX_UNCONFIRMED andTimestamp:0 forTxHashes:txHashes];
        b = block;

        while (b.height > b2.height) { // set transaction heights for new main chain
            [self setBlockHeight:b.height andTimestamp:txTime - NSTimeIntervalSince1970 forTxHashes:b.txHashes];
            b = self.blocks[uint256_obj(b.prevBlock)];
            txTime = b.timestamp/2 + ((BRMerkleBlock *)self.blocks[uint256_obj(b.prevBlock)]).timestamp/2;
        }

        self.lastBlock = block;
    }
    
    if (block.height == peer.lastblock && block == self.lastBlock) { // chain download is complete
        self.syncStartHeight = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:SYNC_STARTHEIGHT_KEY];
        [self saveBlocks];
        [self loadMempools];
    }

    // check if the next block was received as an orphan
    if (block == self.lastBlock && self.orphans[blockHash]) {
        BRMerkleBlock *b = self.orphans[blockHash];

        [self.orphans removeObjectForKey:blockHash];
        [self peer:peer relayedBlock:b];
    }

    if (block.height > _estimatedBlockHeight) _estimatedBlockHeight = block.height;
    
    if (block.height > peer.lastblock) { // notify that transaction confirmations may have changed
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BRPeerManagerTxStatusNotification object:nil];
        });
    }
}

- (void)peer:(BRPeer *)peer notfoundTxHashes:(NSArray *)txHashes andBlockHashes:(NSArray *)blockhashes
{
    for (NSValue *hash in txHashes) {
        [self.txRelays[hash] removeObject:peer];
        [self.txRequests[hash] removeObject:peer];
    }
}

- (BRTransaction *)peer:(BRPeer *)peer requestedTransaction:(UInt256)txHash
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSValue *hash = uint256_obj(txHash);
    BRTransaction *tx = self.publishedTx[hash];
    void (^callback)(NSError *error) = self.publishedCallback[hash];
    NSError *error = nil;

    if (! self.txRelays[hash]) self.txRelays[hash] = [NSMutableSet set];
    [self.txRelays[hash] addObject:peer];
    [self.nonFpTx addObject:hash];
    [self.publishedCallback removeObjectForKey:hash];
    
    if (callback && ! [manager.wallet transactionIsValid:tx]) {
        [self.publishedTx removeObjectForKey:hash];
        error = [NSError errorWithDomain:@"BreadWallet" code:401
                 userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"double spend", nil)}];
    }
    else if (tx && ! [manager.wallet transactionForHash:txHash] && [manager.wallet registerTransaction:tx]) {
        [[BRTransactionEntity context] performBlock:^{
            [BRTransactionEntity saveContext]; // persist transactions to core data
        }];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(txTimeout:) object:hash];
        if (callback) callback(error);
    });

    [peer sendPingMessageWithPongHandler:^(BOOL success) { // check if peer will relay the transaction back
        if (! success) return;
        
        if (! [self.txRequests[hash] containsObject:peer]) {
            if (! self.txRequests[hash]) self.txRequests[hash] = [NSMutableSet set];
            [self.txRequests[hash] addObject:peer];
            [peer sendGetdataMessageWithTxHashes:@[hash] andBlockHashes:nil];
        }
    }];

    return tx;
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    [self rescan];
}

@end

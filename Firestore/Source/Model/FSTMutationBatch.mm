/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Model/FSTMutationBatch.h"

#include <algorithm>
#include <utility>

#import "FIRTimestamp.h"

#include "Firestore/core/src/firebase/firestore/model/document_map.h"
#include "Firestore/core/src/firebase/firestore/objc/objc_compatibility.h"
#include "Firestore/core/src/firebase/firestore/timestamp_internal.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/hashing.h"

namespace objc = firebase::firestore::objc;
using firebase::Timestamp;
using firebase::TimestampInternal;
using firebase::firestore::model::BatchId;
using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::DocumentKeyHash;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::DocumentVersionMap;
using firebase::firestore::model::MaybeDocument;
using firebase::firestore::model::MaybeDocumentMap;
using firebase::firestore::model::Mutation;
using firebase::firestore::model::MutationResult;
using firebase::firestore::model::SnapshotVersion;
using firebase::firestore::util::Hash;

NS_ASSUME_NONNULL_BEGIN

@implementation FSTMutationBatch {
  Timestamp _localWriteTime;
  std::vector<Mutation> _baseMutations;
  std::vector<Mutation> _mutations;
}

- (instancetype)initWithBatchID:(BatchId)batchID
                 localWriteTime:(const Timestamp &)localWriteTime
                  baseMutations:(std::vector<Mutation> &&)baseMutations
                      mutations:(std::vector<Mutation> &&)mutations {
  HARD_ASSERT(!mutations.empty(), "Cannot create an empty mutation batch");
  self = [super init];
  if (self) {
    _batchID = batchID;
    _localWriteTime = localWriteTime;
    _baseMutations = std::move(baseMutations);
    _mutations = std::move(mutations);
  }
  return self;
}

- (const std::vector<Mutation> &)baseMutations {
  return _baseMutations;
}

- (const std::vector<Mutation> &)mutations {
  return _mutations;
}

- (BOOL)isEqual:(id)other {
  if (self == other) {
    return YES;
  } else if (![other isKindOfClass:[FSTMutationBatch class]]) {
    return NO;
  }

  FSTMutationBatch *otherBatch = (FSTMutationBatch *)other;
  return self.batchID == otherBatch.batchID && self.localWriteTime == otherBatch.localWriteTime &&
         _baseMutations == otherBatch.baseMutations && _mutations == otherBatch.mutations;
}

- (NSUInteger)hash {
  NSUInteger result = (NSUInteger)self.batchID;
  result = result * 31 + TimestampInternal::Hash(self.localWriteTime);
  for (const Mutation &mutation : _baseMutations) {
    result = result * 31 + mutation.Hash();
  }
  for (const Mutation &mutation : _mutations) {
    result = result * 31 + mutation.Hash();
  }
  return result;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"<FSTMutationBatch: id=%d, localWriteTime=%s, mutations=%@>",
                                    self.batchID, self.localWriteTime.ToString().c_str(),
                                    objc::Description(_mutations)];
}

- (absl::optional<MaybeDocument>)applyToRemoteDocument:(absl::optional<MaybeDocument>)maybeDoc
                                           documentKey:(const DocumentKey &)documentKey
                                   mutationBatchResult:
                                       (FSTMutationBatchResult *_Nullable)mutationBatchResult {
  HARD_ASSERT(!maybeDoc || maybeDoc->key() == documentKey,
              "applyTo: key %s doesn't match maybeDoc key %s", documentKey.ToString(),
              maybeDoc->key().ToString());

  HARD_ASSERT(mutationBatchResult.mutationResults.size() == _mutations.size(),
              "Mismatch between mutations length (%s) and results length (%s)", _mutations.size(),
              mutationBatchResult.mutationResults.size());

  for (size_t i = 0; i < _mutations.size(); i++) {
    const Mutation &mutation = _mutations[i];
    const MutationResult &mutationResult = mutationBatchResult.mutationResults[i];
    if (mutation.key() == documentKey) {
      maybeDoc = mutation.ApplyToRemoteDocument(maybeDoc, mutationResult);
    }
  }
  return maybeDoc;
}

- (absl::optional<MaybeDocument>)applyToLocalDocument:(absl::optional<MaybeDocument>)maybeDoc
                                          documentKey:(const DocumentKey &)documentKey {
  HARD_ASSERT(!maybeDoc || maybeDoc->key() == documentKey,
              "applyTo: key %s doesn't match maybeDoc key %s", documentKey.ToString(),
              maybeDoc->key().ToString());

  // First, apply the base state. This allows us to apply non-idempotent transform against a
  // consistent set of values.
  for (const Mutation &mutation : _baseMutations) {
    if (mutation.key() == documentKey) {
      maybeDoc = mutation.ApplyToLocalView(maybeDoc, maybeDoc, self.localWriteTime);
    }
  }

  absl::optional<MaybeDocument> baseDoc = maybeDoc;

  // Second, apply all user-provided mutations.
  for (const Mutation &mutation : _mutations) {
    if (mutation.key() == documentKey) {
      maybeDoc = mutation.ApplyToLocalView(maybeDoc, baseDoc, self.localWriteTime);
    }
  }
  return maybeDoc;
}

- (MaybeDocumentMap)applyToLocalDocumentSet:(const MaybeDocumentMap &)documentSet {
  // TODO(mrschmidt): This implementation is O(n^2). If we iterate through the mutations first (as
  // done in `applyToLocalDocument:documentKey:`), we can reduce the complexity to O(n).

  MaybeDocumentMap mutatedDocuments = documentSet;
  for (const Mutation &mutation : _mutations) {
    const DocumentKey &key = mutation.key();

    absl::optional<MaybeDocument> previousDocument = mutatedDocuments.get(key);
    absl::optional<MaybeDocument> mutatedDocument =
        [self applyToLocalDocument:std::move(previousDocument) documentKey:key];
    if (mutatedDocument) {
      mutatedDocuments = mutatedDocuments.insert(key, *mutatedDocument);
    }
  }
  return mutatedDocuments;
}

- (DocumentKeySet)keys {
  DocumentKeySet set;
  for (const Mutation &mutation : _mutations) {
    set = set.insert(mutation.key());
  }
  return set;
}

@end

#pragma mark - FSTMutationBatchResult

@interface FSTMutationBatchResult ()
- (instancetype)initWithBatch:(FSTMutationBatch *)batch
                commitVersion:(SnapshotVersion)commitVersion
              mutationResults:(std::vector<MutationResult>)mutationResults
                  streamToken:(nullable NSData *)streamToken
                  docVersions:(DocumentVersionMap)docVersions NS_DESIGNATED_INITIALIZER;
@end

@implementation FSTMutationBatchResult {
  SnapshotVersion _commitVersion;
  std::vector<MutationResult> _mutationResults;
  DocumentVersionMap _docVersions;
}

- (instancetype)initWithBatch:(FSTMutationBatch *)batch
                commitVersion:(SnapshotVersion)commitVersion
              mutationResults:(std::vector<MutationResult>)mutationResults
                  streamToken:(nullable NSData *)streamToken
                  docVersions:(DocumentVersionMap)docVersions {
  if (self = [super init]) {
    _batch = batch;
    _commitVersion = std::move(commitVersion);
    _mutationResults = std::move(mutationResults);
    _streamToken = streamToken;
    _docVersions = std::move(docVersions);
  }
  return self;
}

- (const SnapshotVersion &)commitVersion {
  return _commitVersion;
}

- (const std::vector<MutationResult> &)mutationResults {
  return _mutationResults;
}

- (const DocumentVersionMap &)docVersions {
  return _docVersions;
}

+ (instancetype)resultWithBatch:(FSTMutationBatch *)batch
                  commitVersion:(SnapshotVersion)commitVersion
                mutationResults:(std::vector<MutationResult>)mutationResults
                    streamToken:(nullable NSData *)streamToken {
  HARD_ASSERT(batch.mutations.size() == mutationResults.size(),
              "Mutations sent %s must equal results received %s", batch.mutations.size(),
              mutationResults.size());

  DocumentVersionMap docVersions;
  std::vector<Mutation> mutations = batch.mutations;
  for (size_t i = 0; i < mutations.size(); i++) {
    absl::optional<SnapshotVersion> version = mutationResults[i].version();
    if (!version) {
      // deletes don't have a version, so we substitute the commitVersion
      // of the entire batch.
      version = commitVersion;
    }

    docVersions[mutations[i].key()] = version.value();
  }

  return [[FSTMutationBatchResult alloc] initWithBatch:batch
                                         commitVersion:std::move(commitVersion)
                                       mutationResults:std::move(mutationResults)
                                           streamToken:streamToken
                                           docVersions:std::move(docVersions)];
}

@end
NS_ASSUME_NONNULL_END

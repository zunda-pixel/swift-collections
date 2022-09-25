//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// MARK: Subtree-level in-place mutation operations

extension _Node {
  @inlinable
  internal mutating func ensureUnique(
    level: _Level, at path: _UnsafePath
  ) -> (leaf: _UnmanagedNode, slot: _Slot) {
    ensureUnique(isUnique: isUnique())
    guard level < path.level else { return (unmanaged, path.currentItemSlot) }
    return update {
      $0[child: path.childSlot(at: level)]
        .ensureUnique(level: level.descend(), at: path)
    }
  }
}

extension _Node {
  @usableFromInline
  @frozen
  internal struct ValueUpdateState {
    @usableFromInline
    internal var key: Key

    @usableFromInline
    internal var value: Value?

    @usableFromInline
    internal let hash: _Hash

    @usableFromInline
    internal var path: _UnsafePath

    @usableFromInline
    internal var found: Bool

    @inlinable
    internal init(
      _ key: Key,
      _ hash: _Hash,
      _ path: _UnsafePath
    ) {
      self.key = key
      self.value = nil
      self.hash = hash
      self.path = path
      self.found = false
    }
  }

  @inlinable
  internal mutating func prepareValueUpdate(
    _ key: Key,
    _ hash: _Hash
  ) -> ValueUpdateState {
    var state = ValueUpdateState(key, hash, _UnsafePath(root: raw))
    _prepareValueUpdate(&state)
    return state
  }

  @inlinable
  internal mutating func _prepareValueUpdate(
    _ state: inout ValueUpdateState
  ) {
    // This doesn't make room for a new item if the key doesn't already exist
    // but it does ensure that all parent nodes along its eventual path are
    // uniquely held.
    //
    // If the key already exists, we ensure uniqueness for its node and extract
    // its item but otherwise leave the tree as it was.
    let isUnique = self.isUnique()
    let r = find(state.path.level, state.key, state.hash, forInsert: true)
    switch r {
    case .found(_, let slot):
      ensureUnique(isUnique: isUnique)
      state.path.node = unmanaged
      state.path.selectItem(at: slot)
      state.found = true
      (state.key, state.value) = update { $0.itemPtr(at: slot).move() }

    case .notFound(_, let slot):
      state.path.selectItem(at: slot)

    case .newCollision(_, let slot):
      state.path.selectItem(at: slot)

    case .expansion(_):
      state.path.selectEnd()

    case .descend(_, let slot):
      ensureUnique(isUnique: isUnique)
      state.path.selectChild(at: slot)
      state.path.descend()
      update { $0[child: slot]._prepareValueUpdate(&state) }
    }
  }

  @inlinable
  internal mutating func finalizeValueUpdate(
    _ state: __owned ValueUpdateState
  ) {
    switch (state.found, state.value != nil) {
    case (true, true):
      // Fast path: updating an existing value.
      UnsafeHandle.update(state.path.node) {
        $0.itemPtr(at: state.path.currentItemSlot)
          .initialize(to: (state.key, state.value.unsafelyUnwrapped))
      }
    case (true, false):
      // Removal
      _finalizeRemoval(.top, state.hash, at: state.path)
    case (false, true):
      // Insertion
      let inserted = insert(
        (state.key, state.value.unsafelyUnwrapped), .top, state.hash)
      assert(inserted)
    case (false, false):
      // Noop
      break
    }
  }

  @inlinable
  internal mutating func _finalizeRemoval(
    _ level: _Level, _ hash: _Hash, at path: _UnsafePath
  ) {
    assert(isUnique())
    if level == path.level {
      _removeItemFromUniqueLeafNode(
        level, hash[level], path.currentItemSlot, by: { _ in })
    } else {
      let slot = path.childSlot(at: level)
      let needsInlining = update {
        let child = $0.childPtr(at: slot)
        child.pointee._finalizeRemoval(level.descend(), hash, at: path)
        return child.pointee.hasSingletonItem
      }
      _fixupUniqueAncestorAfterItemRemoval(
        slot, { _ in hash[level] }, needsInlining: needsInlining)
    }
  }
}

extension _Node {
  @usableFromInline
  @frozen
  internal struct DefaultedValueUpdateState {
    @usableFromInline
    internal var item: Element

    @usableFromInline
    internal var node: _UnmanagedNode

    @usableFromInline
    internal var slot: _Slot

    @usableFromInline
    internal var inserted: Bool

    @inlinable
    internal init(
      _ item: Element,
      in node: _UnmanagedNode,
      at slot: _Slot,
      inserted: Bool
    ) {
      self.item = item
      self.node = node
      self.slot = slot
      self.inserted = inserted
    }
  }

  @inlinable
  internal mutating func prepareDefaultedValueUpdate(
    _ level: _Level,
    _ key: Key,
    _ defaultValue: () -> Value,
    _ hash: _Hash
  ) -> DefaultedValueUpdateState {
    let isUnique = self.isUnique()
    let r = find(level, key, hash, forInsert: true)
    switch r {
    case .found(_, let slot):
      ensureUnique(isUnique: isUnique)
      return DefaultedValueUpdateState(
        update { $0.itemPtr(at: slot).move() },
        in: unmanaged,
        at: slot,
        inserted: false)

    case .notFound(let bucket, let slot):
      ensureUniqueAndInsertItem(isUnique: isUnique, slot, bucket) { _ in }
      return DefaultedValueUpdateState(
        (key, defaultValue()),
        in: unmanaged,
        at: slot,
        inserted: true)

    case .newCollision(let bucket, let slot):
      let r = ensureUniqueAndMakeNewCollision(
        isUnique: isUnique,
        level: level,
        replacing: slot, bucket,
        newHash: hash) { _ in }
      return DefaultedValueUpdateState(
        (key, defaultValue()),
        in: r.leaf,
        at: r.slot,
        inserted: true)

    case .expansion(let collisionHash):
      let r = _Node.build(
        level: level,
        item1: { _ in }, hash,
        child2: self, collisionHash
      )
      self = r.top
      return DefaultedValueUpdateState(
        (key, defaultValue()),
        in: r.leaf,
        at: r.slot1,
        inserted: true)

    case .descend(_, let slot):
      ensureUnique(isUnique: isUnique)
      let res = update {
        $0[child: slot].prepareDefaultedValueUpdate(
          level.descend(), key, defaultValue, hash)
      }
      if res.inserted { count &+= 1 }
      return res
    }
  }

  @inlinable
  internal mutating func finalizeDefaultedValueUpdate(
    _ state: __owned DefaultedValueUpdateState
  ) {
    UnsafeHandle.update(state.node) {
      $0.itemPtr(at: state.slot).initialize(to: state.item)
    }
  }
}

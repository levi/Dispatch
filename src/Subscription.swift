//
//  Created by Virgilio Favero Neto on 4/02/2016.
//  Copyright © 2016 Benjamin Encz. All rights reserved.
//

/// A box around subscriptions and subscribers.
///
/// Acts as a type-erasing wrapper around a subscription and its transformed subscription.
/// The transformed subscription has a type argument that matches the selected substate of the
/// subscriber; however that type cannot be exposed to the store.
///
/// The box subscribes either to the original subscription, or if available to the transformed
/// subscription and passes any values that come through this subscriptions to the subscriber.
class SubscriptionBox<State>: Hashable {
  
  private let subscription: Subscription<State>

  private let objectIdentifier: ObjectIdentifier
  
  weak var subscriber: AnyObject?
  
  private var onChange: (Any) -> Void
  
  init(subscriber: AnyObject, subscription: Subscription<State>, onChange: @escaping (State) -> Void) {
    self.subscription = subscription
    self.objectIdentifier = ObjectIdentifier(subscriber)
    self.subscriber = subscriber
    self.onChange = { state in
      if let typedState = state as? State {
        onChange(typedState)
      }
    }
    
    subscription.observer = { [unowned self] _, newState in
      self.onChange(newState)
    }
  }
  
  init<SelectedState>(
    subscriber: AnyObject,
    subscription: Subscription<State>,
    selectedSubscription: Subscription<SelectedState>,
    onChange: @escaping (SelectedState) -> Void
  ) {
    self.subscription = subscription
    self.objectIdentifier = ObjectIdentifier(subscriber)
    self.subscriber = subscriber
    self.onChange = { state in
      if let typedState = state as? SelectedState {
        onChange(typedState)
      }
    }
    
    selectedSubscription.observer = { [unowned self] _, newState in
      self.onChange(newState)
    }
  }
  
  func newValues(oldState: State?, newState: State) {
    // We pass all new values through the original subscription, which accepts
    // values of type `<State>`. If present, transformed subscriptions will
    // receive this update and transform it before passing it on to the subscriber.
    self.subscription.newValues(oldState: oldState, newState: newState)
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(self.objectIdentifier)
  }
  
  static func == (left: SubscriptionBox<State>, right: SubscriptionBox<State>) -> Bool {
    return left.objectIdentifier == right.objectIdentifier
  }
}

/// Represents a subscription of a subscriber to the store. The subscription determines which new
/// values from the store are forwarded to the subscriber, and how they are transformed.
/// The subscription acts as a very-light weight signal/observable that you might know from
/// reactive programming libraries.
public class Subscription<State> {
  
  /// The closure called with changes from the store.
  /// This closure can be written to for use in extensions to Subscription similar to `skipRepeats`
  public var observer: ((State?, State) -> Void)?
  
  // MARK: Internals
  
  init() {}
  
  // MARK: Public Interface
  
  /// Initializes a subscription with a sink closure. The closure provides a way to send
  /// new values over this subscription.
  public init(sink: @escaping (@escaping (State?, State) -> Void) -> Void) {
    // Provide the caller with a closure that will forward all values
    // to observers of this subscription.
    sink { old, new in
      self.newValues(oldState: old, newState: new)
    }
  }
  
  /// Provides a subscription that selects a substate of the state of the original subscription.
  /// - parameter selector: A closure that maps a state to a selected substate
  public func select<Substate>(_ selector: @escaping (State) -> Substate) -> Subscription<Substate> {
    return self._select(selector)
  }
  
  /// Provides a subscription that skips certain state updates of the original subscription.
  /// - parameter isRepeat: A closure that determines whether a given state update is a repeat and
  /// thus should be skipped and not forwarded to subscribers.
  /// - parameter oldState: The store's old state, before the action is reduced.
  /// - parameter newState: The store's new state, after the action has been reduced.
  /// - paramater action: The action that invoked this change
  public func skipRepeats(_ isRepeat: @escaping (_ oldState: State, _ newState: State) -> Bool)
    -> Subscription<State> {
      return Subscription<State> { sink in
        self.observer = { oldState, newState in
          switch (oldState, newState) {
          case let (old?, new):
            if !isRepeat(old, new) {
              sink(oldState, newState)
            } else {
              return
            }
          default:
            sink(oldState, newState)
          }
        }
      }
  }
  
  // MARK: Internal Interface
  
  /// Sends new values over this subscription. Observers will be notified of these new values.
  func newValues(oldState: State?, newState: State) {
    self.observer?(oldState, newState)
  }
  
  // MARK: Private Interface
  
  private func _select<Substate>(
    _ selector: @escaping (State) -> Substate
  ) -> Subscription<Substate>
  {
    return Subscription<Substate> { sink in
      self.observer = { oldState, newState in
        sink(oldState.map(selector) ?? nil, selector(newState))
      }
    }
  }
}

extension Subscription where State: Equatable {
  public func skipRepeats() -> Subscription<State>{
    return self.skipRepeats(==)
  }
}

/// Subscription skipping convenience methods
extension Subscription {
  
  /// Provides a subscription that skips certain state updates of the original subscription.
  ///
  /// This is identical to `skipRepeats` and is provided simply for convenience.
  /// - parameter when: A closure that determines whether a given state update is a repeat and
  /// thus should be skipped and not forwarded to subscribers.
  /// - parameter oldState: The store's old state, before the action is reduced.
  /// - parameter newState: The store's new state, after the action has been reduced.
  public func skip(when: @escaping (_ oldState: State, _ newState: State) -> Bool) -> Subscription<State> {
    return self.skipRepeats(when)
  }
  
  /// Provides a subscription that only updates for certain state changes.
  ///
  /// This is effectively the inverse of `skip(when:)` / `skipRepeats(:)`
  /// - parameter when: A closure that determines whether a given state update should notify
  /// - parameter oldState: The store's old state, before the action is reduced.
  /// - parameter newState: The store's new state, after the action has been reduced.
  /// the subscriber.
  public func only(when: @escaping (_ oldState: State, _ newState: State) -> Bool) -> Subscription<State> {
    return self.skipRepeats { oldState, newState in
      return !when(oldState, newState)
    }
  }
}

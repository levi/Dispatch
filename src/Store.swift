import Foundation

/// Models that are going to accessed through a store must conform to this protocol.
public protocol ModelType {
  /// Mandatory empty constructor.
  init()
}

/// Mark a store model as immutable.
/// - note: If you implement your model using structs, conform to this protocol.
public protocol ImmutableModelType: ModelType { }

/// This function is used to copy the values of all enumerable own properties from one or more
/// source struct to a target struct. It will return the target struct.
/// - note: This is analogous to Object.assign in Javascript and should be used to update
/// ImmutableModelTypes.
public func assign<T>(_ value: T, changes: (inout T) -> Void) -> T {
  guard Mirror(reflecting: value).displayStyle == .struct else {
    fatalError("'value' must be a struct.")
  }
  var copy = value
  changes(&copy)
  return copy
}

/// Wraps an observer object.
struct StoreObserver<State: ModelType, A: ActionType> {
  // The actual reference to the observer.
  fileprivate weak var ref: AnyObject?
  // The onChange callback that is going to be executed for this observer.
  fileprivate let closure: Store<State, A>.OnChange

  /// Constructs a new observer wrapper object.
  init(_ ref: AnyObject, closure: @escaping Store<State, A>.OnChange) {
    self.ref = ref
    self.closure = closure
  }
}

public protocol StoreType: class {
  /// The unique identifier for this store.
  var identifier: String { get set }
  /// Opaque reference to the model wrapped by this store.
  var modelRef: ModelType { get }
  /// Whether this 'store' comply with the action passed as argument.
  func responds(to action: ActionType) -> Bool
  /// Returns the operation for the action passed as argument.
  func operation(action: ActionType, completion: (() -> Void)?) -> Operation?
  /// Inject the model in the store.
  /// - note: Use this mostly for interactive debugging.
  func inject(model: ModelType, action: ActionType)
}


open class Store<S: ModelType, A: ActionType>: StoreType {

  typealias SubscriptionType = SubscriptionBox<S>
  
  /// The current state for the Store.
  public private(set) var model: S {
    didSet {
      oldModel = oldValue
    }
  }

  /// The block executed whenever the store changes.
  public typealias OnChange = (S, Action<A>?) -> (Void)
  /// Opaque reference to the model wrapped by this store.
  public var modelRef: ModelType { return model }
  /// The reducer function for this store.
  public let reducer: Reducer<S, A>
  /// The unique identifier of the store.
  public var identifier: String
  // Syncronizes the access tp the state object.
  private let stateLock = NSRecursiveLock()
  // The observers currently registered in this store.
  private var observers: [StoreObserver<S, A>] = []
  
  private var subscriptions: Set<SubscriptionType> = []
  
  private var oldModel: S?

  public init(identifier: String, model: S = S(), reducer: Reducer<S, A>) {
    self.identifier = identifier
    self.reducer = reducer
    self.model = model
  }
  
  open func subscribe(_ subscriber: AnyObject, onChange: @escaping (S) -> Void) {
    let subscription = Subscription<S>()
    let subscriptionBox = SubscriptionBox(
      subscriber: subscriber,
      subscription: subscription,
      onChange: onChange
    )
    addSubscription(subscriptionBox)
  }

  open func subscribe<SelectedState>(
    _ subscriber: AnyObject,
    selector: @escaping (Subscription<S>) -> Subscription<SelectedState>,
    onChange: @escaping (SelectedState) -> Void
  ) {
    // Create a subscription for the new subscriber.
    let subscription = Subscription<S>()
    // Call the optional transformation closure. This allows callers to modify
    // the subscription, e.g. in order to subselect parts of the store's state.
    let selectedSubscription = selector(subscription)

    let subscriptionBox = SubscriptionBox(
      subscriber: subscriber,
      subscription: subscription,
      selectedSubscription: selectedSubscription,
      onChange: onChange
    )
    
    addSubscription(subscriptionBox)
  }
  
  public func unsubscribe(_ subscriber: AnyObject) {
    if let index = subscriptions.firstIndex(where: { return $0.subscriber === subscriber }) {
      subscriptions.remove(at: index)
    }
  }
  
  /// Adds a new observer to the store.
  /// - note: The same observer can be added several times with different *onChange* blocks.
  public func register(observer: AnyObject, onChange: @escaping OnChange) {
    precondition(Thread.isMainThread)

    let observer = StoreObserver<S, A>(observer, closure: onChange)
    observers = observers.filter { $0.ref != nil }
    observers.append(observer)
    
    // Notify observer immediately upon registration
    observer.closure(self.model, nil)
  }

  /// Unregister the observer passed as argument.
  public func unregister(observer: AnyObject) {
    precondition(Thread.isMainThread)
    observers = observers.filter { $0.ref != nil && $0.ref !== observer }
  }
  
  /// Whether this 'store' comply with the action passed as argument.
  public func responds(to action: ActionType) -> Bool {
    guard let _ = action as? A else { return false }
    return true
  }

  /// Called from the reducer to update the store state.
  /// Invoking this will cause subscriptions to be notified.
  public func updateModel(closure: (inout S) -> (Void)) {
    self.stateLock.lock()
    closure(&self.model)
    self.stateLock.unlock()
  }

  /// Notify the store observers for the change of this store.
  /// - note: Observers are always notified on the main thread.
  public func notifyObservers(action: Action<A>) {
    func notify() {
      for observer in self.observers where observer.ref != nil {
        observer.closure(self.model, action)
      }
    }
    // Makes sure the observers are notified on the main thread.
    if Thread.isMainThread {
      notify()
    } else {
      DispatchQueue.main.sync(execute: notify)
    }
  }
  
  /// Notify the store subscriptions for the change of this store.
  /// - note: Observers are always notified on the main thread.
  public func notifySubscriptions(action: Action<A>, oldState: S) {
    func notify() {
      subscriptions.forEach {
        if $0.subscriber == nil {
          subscriptions.remove($0)
        } else {
          $0.newValues(oldState: oldState, newState: model)
        }
      }
    }

    // Makes sure the observers are notified on the main thread.
    if Thread.isMainThread {
      notify()
    } else {
      DispatchQueue.main.sync(execute: notify)
    }
  }

  /// Inject the model in the store.
  /// - note: Use this mostly for interactive debugging.
  public func inject(model: ModelType, action: ActionType) {
    guard let model = model as? S, let action = action as? A else {  return }
    self.updateModel { [weak self] _ in
      guard let `self` = self else { return }
      self.model = model
      let time = Date().timeIntervalSince1970
      let action = Action( action: action, model: .finished, lastRun: time, userInfo: [:])
      self.notifyObservers(action: action)
    }
  }

  /// Package the operation returned from the 'Reducer'.
  public func operation(
    action: ActionType,
    completion: (() -> (Void))? = nil
  ) -> Operation? {
    guard let action = action as? A else { return nil }
    // Retrieve the operation from the 'Reducer'.
    guard let operation = self.reducer.operation(for: action, in: self) else { return nil }
    let shouldNotifyObservers = self.reducer.shouldNotifyObservers(for: action, in: self)
    operation.finishBlock = { [weak self] in
      guard let `self` = self else { return }
      if shouldNotifyObservers, let oldModel = self.oldModel {
        let time = Date().timeIntervalSince1970
        let action = Action(action: action, model: .finished, lastRun: time,  userInfo: [:])
        self.notifyObservers(action: action)

        self.notifySubscriptions(action: action, oldState: oldModel)
      }
      // Run the completion provided from the 'Dispatcher'.
      completion?()
    }
    return operation
  }
  
  private func addSubscription(_ subscription: SubscriptionBox<S>) {
    subscriptions.update(with: subscription)
    // Fire subscription immediately upon initialization
    subscription.newValues(oldState: nil, newState: model)
  }
}


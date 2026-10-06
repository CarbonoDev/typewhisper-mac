import Combine

extension Publisher where Failure == Never, Output: Equatable {
    /// [Perf · finding 12] Mirror a `@MainActor` service's published value into a `@MainActor`
    /// view model's property: synchronously (no `receive(on: .main)` hop — both sides are already
    /// on the main actor, so a hop only lands the mirror a run-loop turn late and costs a second
    /// render pass) and only when the value changed (an equal value publishes nothing).
    ///
    /// `@Published` emits in `willSet`, so the mirror holds the new value before the source's own
    /// property does; once the source's assignment returns, the two are equal.
    @MainActor
    func mirror<Root: AnyObject>(to root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Output>) -> AnyCancellable {
        sink { [weak root] value in
            guard let root, root[keyPath: keyPath] != value else { return }
            root[keyPath: keyPath] = value
        }
    }
}

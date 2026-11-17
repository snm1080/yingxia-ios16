import SwiftUI
import Perception

// iOS still runs on 16.2. The other app targets require native Observation, where
// Perception.Bindable is marked obsolete; keep the system wrapper on those platforms.
#if os(iOS)
typealias AppBindable<Value> = Perception.Bindable<Value>
#else
typealias AppBindable<Value> = SwiftUI.Bindable<Value>
#endif

import Foundation

public enum ConfinementViolation: Error, Equatable {
    case dotDotEscape
    case symlinkEscape(via: String)
    case absoluteOutsideRoot
    case emptyPath
}

/// Resolves guest paths lexically while checking every traversed component for
/// a symlink through the supplied, container-relative file-system boundary.
public struct ConfinedPathResolver {
    private let confinementRoot: String
    private let fileSystem: StorageFileSystem

    public init(confinementRoot: String, fileSystem: StorageFileSystem) {
        self.confinementRoot = confinementRoot
        self.fileSystem = fileSystem
    }

    public func resolve(_ guestPath: String) -> Result<String, ConfinementViolation> {
        guard !guestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyPath)
        }
        guard !guestPath.utf8.contains(0),
              let root = PathSupport.normalizedRootComponents(confinementRoot) else {
            return .failure(.absoluteOutsideRoot)
        }

        let isAbsoluteInput = guestPath.hasPrefix("/")
        let initialOrigin: PendingOrigin = isAbsoluteInput ? .absoluteGuest : .relativeGuest
        var current = isAbsoluteInput ? [String]() : root
        var pending = PathSupport.rawComponents(guestPath).map {
            PendingComponent(component: $0, origin: initialOrigin)
        }
        var cursor = 0
        var symlinkHops = 0

        while cursor < pending.count {
            let item = pending[cursor]
            cursor += 1

            switch item.component {
            case ".":
                continue
            case "..":
                if current == root {
                    return .failure(.dotDotEscape)
                }
                guard PathSupport.isStrictlyInside(current, root: root) else {
                    return .failure(violationOutsideRoot(for: item.origin))
                }
                current.removeLast()
            default:
                current.append(item.component)
                guard PathSupport.isOnRouteOrInside(current, root: root) else {
                    return .failure(violationOutsideRoot(for: item.origin))
                }

                let linkPath = PathSupport.join(current)
                do {
                    guard let destination = try fileSystem.destinationOfSymlink(linkPath) else {
                        continue
                    }

                    symlinkHops += 1
                    guard symlinkHops <= 40 else {
                        return .failure(.symlinkEscape(via: linkPath))
                    }
                    let parent = Array(current.dropLast())
                    guard let target = resolvedTargetComponents(
                        destination: destination,
                        parent: parent,
                        root: root
                    ) else {
                        return .failure(.symlinkEscape(via: linkPath))
                    }

                    // Rewalk the full target from virtual root. This checks
                    // symlinks in its ancestors as well as its final component.
                    current = []
                    let targetOrigin = PendingOrigin.symlink(linkPath)
                    let expansion = target.map {
                        PendingComponent(component: $0, origin: targetOrigin)
                    }
                    pending.insert(contentsOf: expansion, at: cursor)
                } catch {
                    // The resolver has no I/O error case; inability to inspect
                    // a component is conservatively treated as an unsafe link.
                    return .failure(.symlinkEscape(via: linkPath))
                }
            }
        }

        guard PathSupport.isInsideOrEqual(current, root: root) else {
            return .failure(.absoluteOutsideRoot)
        }
        return .success(PathSupport.join(Array(current.dropFirst(root.count))))
    }

    private func resolvedTargetComponents(
        destination: String,
        parent: [String],
        root: [String]
    ) -> [String]? {
        guard !destination.utf8.contains(0) else {
            return nil
        }

        var current = destination.hasPrefix("/") ? [String]() : parent
        guard PathSupport.isOnRouteOrInside(current, root: root) else {
            return nil
        }

        for component in PathSupport.rawComponents(destination) {
            switch component {
            case ".":
                continue
            case "..":
                // A target is rejected as soon as it would leave the root,
                // even if later components would appear to re-enter it.
                if current == root {
                    return nil
                }
                guard PathSupport.isStrictlyInside(current, root: root) else {
                    return nil
                }
                current.removeLast()
            default:
                current.append(component)
                guard PathSupport.isOnRouteOrInside(current, root: root) else {
                    return nil
                }
            }
        }

        return PathSupport.isInsideOrEqual(current, root: root) ? current : nil
    }

    private func violationOutsideRoot(for origin: PendingOrigin) -> ConfinementViolation {
        switch origin {
        case .symlink(let path):
            return .symlinkEscape(via: path)
        case .absoluteGuest, .relativeGuest:
            return .absoluteOutsideRoot
        }
    }

    private struct PendingComponent {
        let component: String
        let origin: PendingOrigin
    }

    private enum PendingOrigin {
        case absoluteGuest
        case relativeGuest
        case symlink(String)
    }
}

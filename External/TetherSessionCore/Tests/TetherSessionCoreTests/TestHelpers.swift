//
//  TestHelpers.swift
//  TetherSessionCoreTests
//
//  Shared helpers: a reference implementation of the transition table used by
//  the cross-product matrix test, plus machine-driving utilities.
//

import Foundation
@testable import TetherSessionCore

/// Bitmask of a phase×event transition legality/state. Mirrors the behavioral
/// specification table. `nil` means the pair is not a legal (phase,event).
enum ReferenceTransition {
    case legal(newPhase: SessionPhase, commands: [SessionCommand], infoDiagnostic: Bool)
    case illegal
}

/// The canonical command lists, expressed once here so the table and matrix
/// tests compare against the same frozen ordering.
enum Spec {

    /// Phase equality that treats any `.failed(_)` value as equal. Used by the
    /// matrix test because a machine can only be driven into *some* failed
    /// variant, and the transition behavior is identical for all of them.
    static func samePhase(_ a: SessionPhase, _ b: SessionPhase) -> Bool {
        switch (a, b) {
        case (.failed, .failed):
            return true
        default:
            return a == b
        }
    }

    static func fullTeardown() -> [SessionCommand] { [
        .snapshotScrollback,
        .emitRestoreSequence,
        .signalShell("SIGHUP"),
        .waitForEngineExit(graceMillis: 2000),
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .releaseWorkspaceScope,
    ] }

    static func crashed(_ code: Int32) -> [SessionCommand] { [
        .emitRestoreSequence,
        .showFailure(.engineCrashed(exitCode: code)),
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .releaseWorkspaceScope,
    ] }

    static func rootfsRemoved() -> [SessionCommand] { [
        .emitRestoreSequence,
        .signalShell("SIGHUP"),
        .waitForEngineExit(graceMillis: 1000),
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .markNeedsBootstrap,
        .showFailure(.rootfsRemoved),
        .releaseWorkspaceScope,
    ] }

    static func workspaceUnavailable() -> [SessionCommand] { [
        .emitRestoreSequence,
        .signalShell("SIGHUP"),
        .waitForEngineExit(graceMillis: 1000),
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .showFailure(.workspaceUnavailable),
        .releaseWorkspaceScope,
    ] }

    static func ptyFailed(_ msg: String) -> [SessionCommand] { [
        .showFailure(.ptyError(msg)),
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .releaseWorkspaceScope,
    ] }

    static func cleanExit() -> [SessionCommand] { [
        .stopOutputPump,
        .closePTYAfterReaderStops,
        .releaseWorkspaceScope,
    ] }

    /// The reference transition for a (phase, event) pair, or `nil` if illegal.
    static func transition(_ phase: SessionPhase, _ event: SessionEvent) -> ReferenceTransition {
        switch phase {

        case .idle:
            switch event {
            case .workspaceOpened:
                return .legal(newPhase: .bootstrapping, commands: [.startBootstrap], infoDiagnostic: false)
            default:
                return .illegal
            }

        case .bootstrapping:
            switch event {
            case .bootstrapSucceeded:
                return .legal(newPhase: .startingShell, commands: [.startShell], infoDiagnostic: false)
            case .bootstrapFailed(let msg):
                let f = SessionFailure.bootstrapFailed(msg)
                return .legal(newPhase: .failed(f), commands: [.showFailure(f)], infoDiagnostic: false)
            case .userRequestedClose:
                return .legal(newPhase: .tearingDown, commands: [.releaseWorkspaceScope], infoDiagnostic: false)
            case .workspaceBecameUnavailable:
                return .legal(newPhase: .failed(.workspaceUnavailable),
                              commands: [.showFailure(.workspaceUnavailable), .releaseWorkspaceScope],
                              infoDiagnostic: false)
            default:
                return .illegal
            }

        case .startingShell:
            switch event {
            case .shellStarted:
                return .legal(newPhase: .active, commands: [], infoDiagnostic: false)
            case .ptyFailed(let msg):
                let f = SessionFailure.ptyError(msg)
                return .legal(newPhase: .failed(f),
                              commands: [.showFailure(f), .releaseWorkspaceScope],
                              infoDiagnostic: false)
            case .shellExited(let code):
                let f = SessionFailure.engineCrashed(exitCode: code)
                return .legal(newPhase: .failed(f),
                              commands: [.showFailure(f), .stopOutputPump,
                                         .closePTYAfterReaderStops, .releaseWorkspaceScope],
                              infoDiagnostic: false)
            case .userRequestedClose:
                return .legal(newPhase: .tearingDown, commands: fullTeardown(), infoDiagnostic: false)
            default:
                return .illegal
            }

        case .active:
            switch event {
            case .userRequestedClose:
                return .legal(newPhase: .tearingDown, commands: fullTeardown(), infoDiagnostic: false)
            case .shellExited(let code) where code == 0:
                return .legal(newPhase: .tearingDown, commands: cleanExit(), infoDiagnostic: false)
            case .shellExited(let code):
                return .legal(newPhase: .failed(.engineCrashed(exitCode: code)),
                              commands: crashed(code), infoDiagnostic: false)
            case .ptyFailed(let msg):
                return .legal(newPhase: .failed(.ptyError(msg)),
                              commands: ptyFailed(msg), infoDiagnostic: false)
            case .rootfsRemovedExternally:
                return .legal(newPhase: .failed(.rootfsRemoved),
                              commands: rootfsRemoved(), infoDiagnostic: false)
            case .workspaceBecameUnavailable:
                return .legal(newPhase: .failed(.workspaceUnavailable),
                              commands: workspaceUnavailable(), infoDiagnostic: false)
            case .appBackgrounded:
                return .legal(newPhase: .suspended, commands: [.snapshotScrollback], infoDiagnostic: false)
            default:
                return .illegal
            }

        case .suspended:
            switch event {
            case .appForegrounded:
                return .legal(newPhase: .active, commands: [], infoDiagnostic: false)
            case .shellExited(let code) where code == 0:
                return .legal(newPhase: .tearingDown, commands: cleanExit(), infoDiagnostic: false)
            case .shellExited(let code):
                return .legal(newPhase: .failed(.engineCrashed(exitCode: code)),
                              commands: crashed(code), infoDiagnostic: false)
            case .rootfsRemovedExternally:
                return .legal(newPhase: .failed(.rootfsRemoved),
                              commands: rootfsRemoved(), infoDiagnostic: false)
            case .userRequestedClose:
                return .legal(newPhase: .tearingDown, commands: fullTeardown(), infoDiagnostic: false)
            default:
                return .illegal
            }

        case .tearingDown:
            switch event {
            case .teardownFinished:
                return .legal(newPhase: .closed, commands: [], infoDiagnostic: false)
            case .shellExited:
                // Informational; phase unchanged; no commands; a diagnostic is written.
                return .legal(newPhase: .tearingDown, commands: [], infoDiagnostic: true)
            case .userRequestedClose:
                // Idempotent teardown; phase unchanged; no commands; a diagnostic is written.
                return .legal(newPhase: .tearingDown, commands: [], infoDiagnostic: true)
            default:
                return .illegal
            }

        case .failed:
            switch event {
            case .retryRequested:
                return .legal(newPhase: .bootstrapping, commands: [.startBootstrap], infoDiagnostic: false)
            case .userRequestedClose:
                return .legal(newPhase: .tearingDown, commands: [.releaseWorkspaceScope], infoDiagnostic: false)
            default:
                return .illegal
            }

        case .closed:
            switch event {
            case .workspaceOpened:
                return .legal(newPhase: .bootstrapping, commands: [.startBootstrap], infoDiagnostic: false)
            default:
                return .illegal
            }
        }
    }

    /// Drive a machine to a given phase, throwing a failure string if impossible.
    static func driveTo(_ machine: SessionStateMachine, _ target: SessionPhase) {
        switch target {
        case .idle:
            return // fresh machine
        case .bootstrapping:
            _ = machine.handle(.workspaceOpened)
        case .startingShell:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
        case .active:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
            _ = machine.handle(.shellStarted)
        case .suspended:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
            _ = machine.handle(.shellStarted)
            _ = machine.handle(.appBackgrounded)
        case .tearingDown:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
            _ = machine.handle(.shellStarted)
            _ = machine.handle(.userRequestedClose)
        case .failed:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
            _ = machine.handle(.shellStarted)
            _ = machine.handle(.ptyFailed("matrix-drive failure"))
            // The actual failure may differ from the requested one; that is fine —
            // the matrix only needs "some failed" to check the phase family.
            break
        case .closed:
            _ = machine.handle(.workspaceOpened)
            _ = machine.handle(.bootstrapSucceeded)
            _ = machine.handle(.shellStarted)
            _ = machine.handle(.userRequestedClose)
            _ = machine.handle(.teardownFinished)
        }
    }
}

//
//  ParityFixtureLoaderSmokeTests.swift
//  MLXAudioTests
//
//  CI-safe: no model downloads. Loads the `dsp` parity fixture and asserts
//  that the three safetensors files are non-empty.
//
//  Part of Sortie 2 — OPERATION ECHO DRAGNET.
//

import Testing
import MLX
import Foundation

// MARK: - ParityFixtureLoaderSmokeTests

@Suite("ParityFixtureLoaderSmokeTests")
struct ParityFixtureLoaderSmokeTests {

    /// Load the `dsp` fixture and verify the three safetensors files each
    /// contain at least one tensor with a non-empty shape.
    ///
    /// `dsp/input.safetensors`    key: "audio"
    /// `dsp/weights.safetensors`  key: "window"
    /// `dsp/expected.safetensors` key: "magnitude"
    @Test func dspFixtureLoadsSuccessfully() throws {
        let fixture = try loadParityFixture("dsp")

        // input.safetensors must contain at least one array with rank > 0
        #expect(
            fixture.input.values.first.map { $0.shape.count > 0 } ?? false,
            "dsp input.safetensors must contain at least one non-scalar tensor"
        )

        // weights.safetensors must contain at least one entry
        #expect(
            fixture.weights.count >= 1,
            "dsp weights.safetensors must contain at least one tensor"
        )

        // expected.safetensors must contain at least one array with rank > 0
        #expect(
            fixture.expected.values.first.map { $0.shape.count > 0 } ?? false,
            "dsp expected.safetensors must contain at least one non-scalar tensor"
        )
    }
}

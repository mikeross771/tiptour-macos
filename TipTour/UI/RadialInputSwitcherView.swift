//
//  RadialInputSwitcherView.swift
//  TipTour
//
//  Cursor-centered visual switcher for choosing how to give TipTour input.
//

import SwiftUI

enum RadialInputOption: String, CaseIterable, Identifiable {
    case speak
    case type
    case highlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speak:
            return "Speak"
        case .type:
            return "Type"
        case .highlight:
            return "Highlight"
        }
    }

    var systemImage: String {
        switch self {
        case .speak:
            return "waveform"
        case .type:
            return "text.cursor"
        case .highlight:
            return "highlighter"
        }
    }

    var offset: CGSize {
        switch self {
        case .speak:
            return CGSize(width: 0, height: -76)
        case .type:
            return CGSize(width: 74, height: 46)
        case .highlight:
            return CGSize(width: -74, height: 46)
        }
    }
}

struct RadialInputSwitcherView: View {
    let highlightedOption: RadialInputOption?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.22))
                .frame(width: 54, height: 54)
                .overlay(
                    Circle()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                )
                .shadow(color: Color.black.opacity(0.32), radius: 16, x: 0, y: 8)

            ForEach(RadialInputOption.allCases) { option in
                radialOptionView(option)
                    .offset(option.offset)
            }
        }
        .frame(width: 220, height: 190)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.86).combined(with: .opacity))
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: highlightedOption?.id)
    }

    private func radialOptionView(_ option: RadialInputOption) -> some View {
        let isHighlighted = highlightedOption == option
        return HStack(spacing: 6) {
            Image(systemName: option.systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(option.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(isHighlighted ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 86)
        .background(
            Capsule()
                .fill(isHighlighted ? DS.Colors.accent : Color.black.opacity(0.48))
        )
        .overlay(
            Capsule()
                .stroke(
                    isHighlighted ? DS.Colors.accent.opacity(0.8) : DS.Colors.borderSubtle,
                    lineWidth: 0.7
                )
        )
        .shadow(
            color: isHighlighted ? DS.Colors.accent.opacity(0.22) : Color.black.opacity(0.24),
            radius: isHighlighted ? 12 : 7,
            x: 0,
            y: 5
        )
    }
}

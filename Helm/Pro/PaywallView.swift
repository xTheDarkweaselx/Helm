//
//  PaywallView.swift
//  Helm
//
//  v9 Paywall foundation: the "Helm Pro" unlock screen. Fully built, but while
//  ProGate.enforced is false it's informational only — every feature is free, so
//  the copy frames Pro as optional support rather than a wall.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(ProStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.helmAccent) private var accent

    private struct Perk: Identifiable { let id = UUID(); let icon: String; let text: String }
    private let perks = [
        Perk(icon: "infinity", text: "A one-time purchase — unlocked forever, no subscription."),
        Perk(icon: "icloud.fill", text: "Works across your iPhone, iPad, Mac and Apple Watch."),
        Perk(icon: "heart.fill", text: "Supports an indie app built by one person."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    VStack(spacing: 12) {
                        ForEach(perks) { perk in
                            HStack(spacing: 12) {
                                Image(systemName: perk.icon).font(.title3).foregroundStyle(accent).frame(width: 30)
                                Text(perk.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    purchaseArea
                    Text("Helm is fully featured right now — Pro simply supports its development. Payment is charged to your Apple Account.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .themedPane(.plain)
            .navigationTitle("Helm Pro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "sailboat.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(LinearGradient(colors: [accent, accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                           in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Helm Pro").font(.largeTitle.weight(.bold))
            Text("A one-time unlock. Yours forever.").font(.title3).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var purchaseArea: some View {
        if store.isPro {
            Label("You have Helm Pro — thank you!", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
        } else {
            Button {
                Task { await store.purchase() }
            } label: {
                Group {
                    if store.isWorking { ProgressView() }
                    else { Text(buyTitle) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(store.product == nil || store.isWorking)

            Button("Restore purchase") { Task { await store.restore() } }
                .disabled(store.isWorking)
        }
        if let message = store.statusMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var buyTitle: String {
        if let product = store.product { return "Unlock for \(product.displayPrice)" }
        return "Unlock Helm Pro"
    }
}

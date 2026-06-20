//
//  ProStore.swift
//  Helm
//
//  v9 Paywall foundation: a StoreKit 2 manager for a single LIFETIME unlock
//  (non-consumable). Loads the product, tracks the entitlement from
//  Transaction.currentEntitlements (StoreKit is the source of truth — nothing is
//  cached in UserDefaults), and handles purchase / restore. Injected once at the
//  app root. NOTE: nothing is gated yet (see ProGate); this is plumbing only.
//

import Foundation
import StoreKit

@Observable
final class ProStore {
    /// The lifetime non-consumable product. Defined in HelmPro.storekit (for
    /// local testing) and to be created in App Store Connect with this exact id.
    static let lifetimeID = "Fusion-Studios.Helm.pro.lifetime"

    private(set) var product: Product?
    private(set) var isPro = false
    private(set) var isWorking = false
    var statusMessage: String?

    init() {
        // Load the product + current entitlement, then keep listening for updates
        // (renewals on other devices, refunds, family sharing) for the app's life.
        Task {
            await loadProduct()
            await refreshEntitlement()
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await refreshEntitlement()
                }
            }
        }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.lifetimeID]).first
        } catch {
            statusMessage = "Couldn't reach the store. Check your connection and try again."
        }
    }

    /// Pro is on when a verified, non-revoked lifetime entitlement exists.
    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.lifetimeID,
               transaction.revocationDate == nil {
                isPro = true
                return
            }
        }
        isPro = false
    }

    func purchase() async {
        guard let product else { return }
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    isPro = true
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restore() async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }
        do {
            try await AppStore.sync()
        } catch {
            statusMessage = "Couldn't restore: \(error.localizedDescription)"
            return
        }
        await refreshEntitlement()
        if !isPro { statusMessage = "No previous Helm Pro purchase was found on this Apple Account." }
    }
}

import StoreKit
import SwiftUI

/// Full-screen paywall view.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showPaywall) {
///     PaywallView()
/// }
/// ```
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var storeManager = StoreKitManager.shared
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    self.headerSection

                    // Products
                    if self.storeManager.isLoading {
                        ProgressView()
                            .padding()
                    } else if self.storeManager.products.isEmpty {
                        Text("Unable to load products")
                            .foregroundStyle(.secondary)
                    } else {
                        self.productsSection
                    }

                    // Features
                    self.featuresSection

                    // Purchase button
                    self.purchaseButton

                    // Restore
                    self.restoreButton

                    // Terms
                    self.termsSection
                }
                .padding()
            }
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        self.dismiss()
                    }
                }
            }
            .task {
                await self.storeManager.loadProducts()
                self.selectedProduct = self.storeManager.yearlyProduct ?? self.storeManager.products.first
            }
            .alert("Error", isPresented: .constant(self.errorMessage != nil)) {
                Button("OK") { self.errorMessage = nil }
            } message: {
                Text(self.errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)

            Text("Unlock All Features")
                .font(.title.bold())

            Text("Get unlimited access to premium features")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    private var productsSection: some View {
        VStack(spacing: 12) {
            ForEach(self.storeManager.products) { product in
                SubscriptionButton(
                    product: product,
                    isSelected: self.selectedProduct?.id == product.id,
                    isPopular: product.id == Products.yearlySubscription,
                    savingsPercent: product.id == Products.yearlySubscription ? self.storeManager.yearlySavingsPercent : nil
                ) {
                    self.selectedProduct = product
                }
            }
        }
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's Included")
                .font(.headline)

            FeatureRow(icon: "checkmark.circle.fill", text: "Unlimited access")
            FeatureRow(icon: "checkmark.circle.fill", text: "Premium features")
            FeatureRow(icon: "checkmark.circle.fill", text: "No ads")
            FeatureRow(icon: "checkmark.circle.fill", text: "Priority support")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }

    private var purchaseButton: some View {
        Button {
            Task {
                await self.purchase()
            }
        } label: {
            Group {
                if self.isPurchasing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Subscribe Now")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(self.selectedProduct == nil || self.isPurchasing)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task {
                await self.restore()
            }
        }
        .font(.footnote)
    }

    private var termsSection: some View {
        VStack(spacing: 4) {
            Text("Subscriptions auto-renew unless cancelled")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Link("Terms", destination: URL(string: "https://yourapp.com/terms")!)
                Text("•")
                Link("Privacy", destination: URL(string: "https://yourapp.com/privacy")!)
            }
            .font(.caption2)
        }
    }

    // MARK: - Actions

    private func purchase() async {
        guard let product = selectedProduct else { return }

        self.isPurchasing = true
        defer { isPurchasing = false }

        do {
            let transaction = try await storeManager.purchase(product)
            if transaction != nil {
                self.dismiss()
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        self.isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await self.storeManager.restorePurchases()
            if self.storeManager.hasActiveSubscription() {
                self.dismiss()
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: self.icon)
                .foregroundStyle(.green)
            Text(self.text)
                .font(.subheadline)
        }
    }
}

// MARK: - Preview

#Preview {
    PaywallView()
}

require "rails_helper"

RSpec.describe SecurityDepositTransactions::VoidService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "voiding a received transaction" do
    it "reverses journal entry on original occurred_on and marks transaction voided" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]
      expect(security_deposit.held_cents).to eq(100_000)

      void_res = described_class.call(transaction: txn, reason: "Entered in error")
      expect(void_res).to be_success
      expect(txn.reload).to be_voided
      expect(security_deposit.held_cents).to eq(0)

      reversal = void_res.value!.data[:journal_entry]
      expect(reversal.occurred_on).to eq(Date.new(2026, 1, 1))
      expect(reversal.description).to eq("Entered in error")
    end

    it "is idempotent on identical retry" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]

      void1 = described_class.call(transaction: txn, reason: "Duplicate")
      expect(void1).to be_success

      void2 = described_class.call(transaction: txn, reason: "Duplicate")
      expect(void2).to be_success
      expect(void2.value!.data[:journal_entry].id).to eq(void1.value!.data[:journal_entry].id)
    end

    it "returns idempotency_conflict when retried with different reason" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]

      described_class.call(transaction: txn, reason: "Reason A")
      void2 = described_class.call(transaction: txn, reason: "Reason B")
      expect(void2).to be_failure
      expect(void2.failure.code).to eq(:idempotency_conflict)
    end

    it "rejects voiding if subsequent withdrawals would create negative liability" do
      # Jan 1: Receive $1000
      res1 = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn1 = res1.value!.data[:transaction]

      # Feb 1: Refund $600
      SecurityDepositTransactions::RefundService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 60_000,
        occurred_on: Date.new(2026, 2, 1)
      )

      # Attempt to void Jan 1 receipt
      void_res = described_class.call(transaction: txn1)
      expect(void_res).to be_failure
      expect(void_res.failure.code).to eq(:negative_deposit_liability)
    end
  end

  describe "voiding an applied transaction" do
    it "restores tenant receivable and deposit held balance, and unblocks charge voiding" do
      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        description: "Repair"
      ).value!.data[:charge]

      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      app_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 10)
      )
      app_txn = app_res.value!.data[:transaction]

      # Charge cannot be voided while deposit application is active
      expect(Charges::VoidService.call(charge: charge)).to be_failure

      # Void the application
      void_res = described_class.call(transaction: app_txn)
      expect(void_res).to be_success
      expect(tenancy.current_balance_cents).to eq(50_000)
      expect(security_deposit.held_cents).to eq(100_000)

      # Charge can now be voided
      expect(Charges::VoidService.call(charge: charge)).to be_success
    end
  end

  describe "error conditions" do
    it "rejects invalid source or missing journal entry" do
      expect(described_class.call(transaction: SecurityDepositTransaction.new).failure.code).to eq(:invalid_source)

      txn = create(:security_deposit_transaction, :received, security_deposit: security_deposit, party: party)
      expect(described_class.call(transaction: txn).failure.code).to eq(:not_found)
    end

    it "rejects voiding an already superseded transaction" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]
      SecurityDepositTransactions::CorrectService.call(transaction: txn, amount_cents: 120_000)

      expect(described_class.call(transaction: txn).failure.code).to eq(:already_superseded)
    end

    it "handles ReverseEntryService failure" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      txn = res.value!.data[:transaction]

      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Reverse failure", code: :reverse_error)
      )
      res_fail = described_class.call(transaction: txn)
      expect(res_fail).to be_failure
      expect(res_fail.failure.code).to eq(:reverse_error)
    end
  end
end

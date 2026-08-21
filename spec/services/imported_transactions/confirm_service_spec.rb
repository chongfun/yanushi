require "rails_helper"

RSpec.describe ImportedTransactions::ConfirmService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user, display_name: "Jane Doe") }
  let!(:tenancy) do
    t = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: t, party: party, role: "tenant")
    t
  end
  let(:source_document) { create(:source_document, user: user, status: "success") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "#call for tenant_receipt" do
    let(:transaction) do
      create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle",
        external_reference: "ZEL123456",
        payer_name: "Jane D Doe"
      )
    end

    it "creates a Receipt, posts balanced Dr Cash / Cr AR journal entries, creates party aliases if requested, and updates transaction" do
      expect {
        result = described_class.call(user: user, transaction: transaction, create_alias: true)
        expect(result).to be_success
        receipt = result.value!.data[:source]
        expect(receipt).to be_a(Receipt)
        expect(receipt.amount_cents).to eq(125_000)
        expect(receipt.received_on).to eq(Date.new(2026, 3, 24))
        expect(receipt.payment_method).to eq("zelle")
        expect(receipt.external_reference).to eq("ZEL123456")

        transaction.reload
        expect(transaction.status).to eq("confirmed")
        expect(transaction.confirmed_source).to eq(receipt)

        expect(party.party_aliases.where(alias_name: "Jane D Doe").exists?).to be(true)

        # Check ledger postings
        entries = JournalEntry.where(source: receipt)
        expect(entries.count).to eq(1)
        entry = entries.first
        expect(entry.postings.count).to eq(2)
        debit = entry.postings.find { |p| p.amount_cents.positive? }
        credit = entry.postings.find { |p| p.amount_cents.negative? }
        expect(debit.account.key).to eq("cash")
        expect(debit.amount_cents).to eq(125_000)
        expect(credit.account.key).to eq("tenant_receivable")
        expect(credit.amount_cents).to eq(-125_000)
      }.to change(Receipt, :count).by(1)
       .and change(JournalEntry, :count).by(1)
       .and change(Posting, :count).by(2)
       .and change(PartyAlias, :count).by(1)
    end

    it "is idempotent and returns existing receipt without double-posting when called multiple times" do
      first_result = described_class.call(user: user, transaction: transaction)
      expect(first_result).to be_success
      first_receipt = first_result.value!.data[:source]

      expect {
        second_result = described_class.call(user: user, transaction: transaction)
        expect(second_result).to be_success
        expect(second_result.value!.data[:source]).to eq(first_receipt)
      }.to change(Receipt, :count).by(0)
       .and change(JournalEntry, :count).by(0)
       .and change(Posting, :count).by(0)
    end

    it "handles domain failure during receipt creation" do
      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Future date invalid", code: :future_date)
      )

      result = described_class.call(user: user, transaction: transaction)
      expect(result).to be_failure
      expect(result.failure.error).to eq("Future date invalid")
      expect(transaction.reload.status).to eq("matched")
    end
  end

  describe "#call for security_deposit" do
    let!(:security_deposit) do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
    end

    let(:transaction) do
      create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "security_deposit",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle",
        external_reference: "DEP123456"
      )
    end

    it "creates a SecurityDepositTransaction(received), posts balanced Dr Cash / Cr Liability, and updates transaction" do
      expect {
        result = described_class.call(user: user, transaction: transaction)
        expect(result).to be_success
        deposit_txn = result.value!.data[:source]
        expect(deposit_txn).to be_a(SecurityDepositTransaction)
        expect(deposit_txn.transaction_kind).to eq("received")
        expect(deposit_txn.amount_cents).to eq(100_000)
        expect(deposit_txn.occurred_on).to eq(Date.new(2026, 3, 24))
        expect(deposit_txn.external_reference).to eq("DEP123456")

        transaction.reload
        expect(transaction.status).to eq("confirmed")
        expect(transaction.confirmed_source).to eq(deposit_txn)

        # Check ledger postings
        entries = JournalEntry.where(source: deposit_txn)
        expect(entries.count).to eq(1)
        entry = entries.first
        expect(entry.postings.count).to eq(2)
        debit = entry.postings.find { |p| p.amount_cents.positive? }
        credit = entry.postings.find { |p| p.amount_cents.negative? }
        expect(debit.account.key).to eq("cash")
        expect(debit.amount_cents).to eq(100_000)
        expect(credit.account.key).to eq("security_deposits_held")
        expect(credit.amount_cents).to eq(-100_000)
      }.to change(SecurityDepositTransaction, :count).by(1)
       .and change(JournalEntry, :count).by(1)
       .and change(Posting, :count).by(2)
    end

    it "fails gracefully when tenancy lacks a security deposit requirement" do
      security_deposit.destroy!

      result = described_class.call(user: user, transaction: transaction)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_confirmable)
      expect(transaction.reload.status).to eq("matched")
    end

    it "handles domain failure during deposit receive service" do
      allow(SecurityDepositTransactions::ReceiveService).to receive(:call).and_return(
        ServiceResult.failure(error: "Deposit limit exceeded", code: :limit_exceeded)
      )

      result = described_class.call(user: user, transaction: transaction)
      expect(result).to be_failure
      expect(result.failure.error).to eq("Deposit limit exceeded")
      expect(transaction.reload.status).to eq("matched")
    end
  end

  describe "guards and edge cases" do
    it "rejects when transaction belongs to another user" do
      foreign_txn = create(:imported_transaction, user: other_user)
      result = described_class.call(user: user, transaction: foreign_txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "rejects confirmation when transaction_kind is unknown" do
      unclassified_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "unknown",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 3, 24)
      )
      result = described_class.call(user: user, transaction: unclassified_txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:classification_required)
      expect(unclassified_txn.reload.status).to eq("matched")
    end

    it "handles confirmed state without confirmed_source" do
      corrupted_txn = create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_document)
      Receipt.where(id: corrupted_txn.confirmed_source_id).delete_all
      corrupted_txn.reload

      result = described_class.call(user: user, transaction: corrupted_txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:confirmation_error)
    end

    it "rescues ActiveRecord::RecordNotUnique" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))

      result = described_class.call(user: user, transaction: txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:duplicate)
    end

    it "rescues ActiveRecord::RecordInvalid" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(Receipt.new))

      result = described_class.call(user: user, transaction: txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:validation_error)
    end

    it "rescues ActiveRecord::RecordNotFound" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle"
      )

      allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordNotFound.new("Party not found"))

      result = described_class.call(user: user, transaction: txn)
      expect(result).to be_failure
      expect(result.failure.code).to eq(:not_found)
    end

    it "creates username alias when create_alias: true and payer_username is a candidate" do
      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "venmo",
        payer_name: "Jane Doe",
        payer_username: "@janedoe-venmo"
      )

      result = described_class.call(user: user, transaction: txn, create_alias: true)
      expect(result).to be_success
      expect(party.party_aliases.where(alias_name: "@janedoe-venmo").exists?).to be(true)
    end
  end

  describe "concurrency" do
    let(:transaction) do
      create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        transaction_kind: "tenant_receipt",
        status: "matched",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 3, 24),
        payment_method: "zelle",
        external_reference: "CONC123"
      )
    end

    it "serializes concurrent confirmations safely without duplicate receipts" do
      threads = []
      results = []

      2.times do
        threads << Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            results << described_class.call(user: user, transaction: transaction)
          end
        end
      end

      threads.each(&:join)

      expect(results.all?(&:success?)).to be(true)
      receipt_ids = results.map { |r| r.value!.data[:source].id }.uniq
      expect(receipt_ids.size).to eq(1)
      expect(Receipt.where(id: receipt_ids.first).count).to eq(1)
    end

    it "serializes concurrent confirm vs update to unknown" do
      t1_res = nil
      t2_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t1_res = described_class.call(user: user, transaction: ImportedTransaction.find(transaction.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t2_res = ImportedTransactions::UpdateService.call(
            user: user,
            transaction: ImportedTransaction.find(transaction.id),
            params: { transaction_kind: "unknown" }
          )
        end
      end

      [ t1, t2 ].each(&:join)

      txn = transaction.reload
      if t1_res.success?
        # Confirm won: record is confirmed tenant_receipt with a Receipt
        expect(t2_res).to be_failure
        expect(t2_res.failure.code).to eq(:immutable)
        expect(txn.status).to eq("confirmed")
        expect(txn.transaction_kind).to eq("tenant_receipt")
        expect(txn.confirmed_source).to be_a(Receipt)
      else
        # Update won: record is unknown, confirm was rejected under lock
        expect(t2_res).to be_success
        expect(t1_res.failure.code).to eq(:classification_required)
        expect(txn.status).not_to eq("confirmed")
        expect(txn.transaction_kind).to eq("unknown")
        expect(txn.confirmed_source).to be_nil
        expect(SecurityDepositTransaction.count).to eq(0)
        expect(Receipt.count).to eq(0)
      end
    end

    it "serializes concurrent confirm vs update to security_deposit" do
      create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000)
      t1_res = nil
      t2_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t1_res = described_class.call(user: user, transaction: ImportedTransaction.find(transaction.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t2_res = ImportedTransactions::UpdateService.call(
            user: user,
            transaction: ImportedTransaction.find(transaction.id),
            params: { transaction_kind: "security_deposit" }
          )
        end
      end

      [ t1, t2 ].each(&:join)

      txn = transaction.reload
      expect(t1_res).to be_success
      if t2_res.success?
        # Update ran before lock: confirmation created a SecurityDepositTransaction
        expect(txn.status).to eq("confirmed")
        expect(txn.transaction_kind).to eq("security_deposit")
        expect(txn.confirmed_source).to be_a(SecurityDepositTransaction)
      else
        # Confirm ran before update: confirmation created a Receipt, update failed
        expect(t2_res.failure.code).to eq(:immutable)
        expect(txn.status).to eq("confirmed")
        expect(txn.transaction_kind).to eq("tenant_receipt")
        expect(txn.confirmed_source).to be_a(Receipt)
      end
    end

    it "serializes concurrent confirm vs clearing required tenancy" do
      t1_res = nil
      t2_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t1_res = described_class.call(user: user, transaction: ImportedTransaction.find(transaction.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          t2_res = ImportedTransactions::UpdateService.call(
            user: user,
            transaction: ImportedTransaction.find(transaction.id),
            params: { matched_tenancy_id: nil }
          )
        end
      end

      [ t1, t2 ].each(&:join)

      txn = transaction.reload
      if t1_res.success?
        # Confirm won: record is confirmed with Receipt
        expect(t2_res).to be_failure
        expect(t2_res.failure.code).to eq(:immutable)
        expect(txn.status).to eq("confirmed")
        expect(txn.confirmed_source).to be_a(Receipt)
      else
        # Update won: tenancy cleared, confirm failed with :not_confirmable
        expect(t2_res).to be_success
        expect(t1_res.failure.code).to eq(:not_confirmable)
        expect(txn.status).to eq("unmatched")
        expect(txn.matched_tenancy_id).to be_nil
        expect(Receipt.count).to eq(0)
      end
    end

    it "handles missing confirmed_source on already confirmed transaction" do
      allow(transaction).to receive(:confirmed?).and_return(true)
      allow(transaction).to receive(:confirmed_source).and_return(nil)
      res = described_class.call(user: user, transaction: transaction)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:confirmation_error)
    end

    it "rescues RecordNotUnique and RecordInvalid during confirmation" do
      allow(transaction).to receive(:update!).and_raise(ActiveRecord::RecordNotUnique, "Unique violation")
      res_dup = described_class.call(user: user, transaction: transaction)
      expect(res_dup).to be_failure
      expect(res_dup.failure.code).to eq(:duplicate)

      allow(transaction).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(transaction))
      res_inv = described_class.call(user: user, transaction: transaction)
      expect(res_inv).to be_failure
      expect(res_inv.failure.code).to eq(:validation_error)
    end
  end
end

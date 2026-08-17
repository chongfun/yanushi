require "rails_helper"

RSpec.describe PaymentIngestions::ConfirmService do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:party) { create(:party, user: user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }

  def build_ingestion(attributes = {})
    create(:payment_ingestion, {
      user: user,
      source: "pdf_upload",
      status: "matched",
      party: party,
      tenancy: tenancy,
      amount: 1200.0,
      payment_date: Date.current,
      payment_method: "venmo",
      transaction_number: "TXN#{SecureRandom.hex(4)}"
    }.merge(attributes))
  end

  it "creates a receipt and marks the ingestion confirmed" do
    ingestion = build_ingestion(transaction_number: "TXNCONFIRM")

    expect {
      result = described_class.call(user: user, ingestion: ingestion)
      expect(result).to be_success
      expect(result.value!.data).to be_a(Receipt)
    }.to change(Receipt, :count).by(1)
     .and change(JournalEntry, :count).by(1)

    expect(ingestion.reload.status).to eq("confirmed")
    expect(ingestion.receipt.external_reference).to eq("TXNCONFIRM")
    expect(ingestion.receipt.payer_party).to eq(party)
  end

  it "returns failure when ingestion belongs to another user" do
    ingestion = build_ingestion(user: other_user)
    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:not_found)
  end

  it "returns existing receipt when ingestion is already confirmed (idempotent)" do
    ingestion = build_ingestion(transaction_number: "TXNIDEM")
    res1 = described_class.call(user: user, ingestion: ingestion)
    expect(res1).to be_success
    first_receipt = res1.value!.data

    expect {
      res2 = described_class.call(user: user, ingestion: ingestion)
      expect(res2).to be_success
      expect(res2.value!.data).to eq(first_receipt)
    }.not_to change(Receipt, :count)
  end

  it "creates aliases only for candidate payer values" do
    create(:party_alias, party: party, alias_name: "@existing")
    ingestion = build_ingestion(payer_name: "Samantha Lopez", payer_username: "@existing")

    expect {
      result = described_class.call(user: user, ingestion: ingestion, create_alias: true)
      expect(result).to be_success
    }.to change(PartyAlias, :count).by(1)

    expect(party.party_aliases.exists?(alias_name: "Samantha Lopez")).to be(true)
  end

  it "handles duplicate transaction number ActiveRecord::RecordNotUnique" do
    ingestion = build_ingestion(transaction_number: "DUPLICATETXN")
    allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordNotUnique)

    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:duplicate)
  end

  it "handles ActiveRecord::RecordInvalid" do
    ingestion = build_ingestion(transaction_number: "INVALIDTXN")
    invalid_r = Receipt.new
    invalid_r.errors.add(:amount_cents, "is invalid")
    allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(invalid_r))

    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:validation_error)
  end

  it "returns a failure when the ingestion is not confirmable" do
    ingestion = build_ingestion(tenancy: nil)

    result = described_class.call(user: user, ingestion: ingestion)

    expect(result).to be_failure
    expect(result.failure.error).to eq("Cannot confirm: missing required fields or duplicate exists")
  end

  it "handles concurrent confirmation idempotently" do
    ingestion = build_ingestion(transaction_number: "TXNRACE")
    results = []

    2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << described_class.call(user: user, ingestion: PaymentIngestion.find(ingestion.id))
        end
      end
    end.each(&:join)

    expect(results.count(&:success?)).to eq(2)
    expect(results.first.value!.data.id).to eq(results.last.value!.data.id)
    expect(ingestion.reload.status).to eq("confirmed")
  end

  it "fails when ingestion becomes non-confirmable inside transaction" do
    ingestion = build_ingestion
    allow(ingestion).to receive(:confirmable?).and_return(true, false)
    result = described_class.call(user: user, ingestion: ingestion)
    expect(result).to be_failure
    expect(result.failure.code).to eq(:confirmation_error)
  end

  it "preserves original receipt reference on ingestion even after receipt correction" do
    ingestion = build_ingestion(transaction_number: "TXNCORRECT")
    confirm_res = described_class.call(user: user, ingestion: ingestion)
    original_receipt = confirm_res.value!.data

    # Correct the receipt
    correct_res = Receipts::CorrectService.call(receipt: original_receipt, amount_cents: 150_000)
    expect(correct_res).to be_success
    replacement_receipt = correct_res.value!.data[:receipt]

    expect(ingestion.reload.receipt).to eq(original_receipt)
    expect(ingestion.receipt.superseded_by).to eq(replacement_receipt)
  end

  describe "concurrency serialization" do
    it "safely serializes concurrent confirm and update" do
      ingestion = build_ingestion(amount: 1000.0, transaction_number: "TXNCONCUR1")
      confirm_result = nil
      update_result = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          confirm_result = described_class.call(user: user, ingestion: PaymentIngestion.find(ingestion.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          update_result = PaymentIngestions::UpdateService.call(
            user: user,
            ingestion: PaymentIngestion.find(ingestion.id),
            params: { amount: 2000.0 }
          )
        end
      end

      [ t1, t2 ].each(&:join)

      expect(ingestion.reload.status).to eq("confirmed")
      expect(ingestion.receipt).to be_present

      if update_result.failure?
        expect(update_result.failure.code).to eq(:immutable)
        expect(ingestion.amount).to eq(1000.0)
        expect(ingestion.receipt.amount).to eq(1000.0)
      else
        expect(update_result).to be_success
        expect(ingestion.amount).to eq(2000.0)
        expect(ingestion.receipt.amount).to eq(2000.0)
      end

      # Invariant: Once confirmed, no further update can succeed
      after_update = PaymentIngestions::UpdateService.call(
        user: user,
        ingestion: ingestion,
        params: { amount: 3000.0 }
      )
      expect(after_update).to be_failure
      expect(after_update.failure.code).to eq(:immutable)
    end

    it "safely serializes concurrent confirm and ingestion delete" do
      ingestion = build_ingestion(transaction_number: "TXNCONCUR2")
      confirm_result = nil
      delete_result = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          confirm_result = described_class.call(user: user, ingestion: PaymentIngestion.find(ingestion.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          delete_result = PaymentIngestions::DestroyService.call(
            user: user,
            ingestion: PaymentIngestion.find(ingestion.id)
          )
        end
      end

      [ t1, t2 ].each(&:join)

      if confirm_result.success?
        expect(ingestion.reload.status).to eq("confirmed")
        expect(ingestion.receipt).to be_present
        expect(Receipt.where(id: confirm_result.value!.data.id)).to exist
        expect(delete_result).to be_failure
        expect(delete_result.failure.code).to eq(:immutable)
      else
        expect(delete_result).to be_success
        expect(PaymentIngestion.where(id: ingestion.id)).to be_empty
        expect(Receipt.where(external_reference: "TXNCONCUR2")).to be_empty
      end
    end

    it "safely serializes concurrent confirm and PaymentDocument delete" do
      doc = create(:payment_document, user: user)
      ingestion = build_ingestion(payment_document: doc, transaction_number: "TXNCONCUR3")
      confirm_result = nil
      delete_result = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          confirm_result = described_class.call(user: user, ingestion: PaymentIngestion.find(ingestion.id))
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          delete_result = PaymentDocuments::DestroyService.call(
            user: user,
            document: PaymentDocument.find(doc.id)
          )
        end
      end

      [ t1, t2 ].each(&:join)

      if confirm_result.success?
        expect(ingestion.reload.status).to eq("confirmed")
        expect(ingestion.receipt).to be_present
        expect(PaymentDocument.where(id: doc.id)).to exist
        expect(delete_result).to be_failure
        expect(delete_result.failure.code).to eq(:immutable)
      else
        expect(delete_result).to be_success
        expect(PaymentDocument.where(id: doc.id)).to be_empty
        expect(PaymentIngestion.where(id: ingestion.id)).to be_empty
        expect(Receipt.where(external_reference: "TXNCONCUR3")).to be_empty
      end
    end

    it "handles confirmed status without receipt record gracefully" do
      ingestion = build_ingestion(transaction_number: "TXNNORCPT")
      ingestion.update_columns(status: :confirmed, receipt_id: nil)

      res = described_class.call(user: user, ingestion: ingestion)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:confirmation_error)
    end

    it "handles missing tenancy or party during receipt creation" do
      ingestion = build_ingestion
      allow(ingestion).to receive(:confirmable?).and_return(true)
      allow(ingestion).to receive(:tenancy).and_return(nil)

      res = described_class.call(user: user, ingestion: ingestion)
      expect(res).to be_failure
      expect(res.failure.error).to include("Missing tenancy")

      allow(ingestion).to receive(:tenancy).and_return(tenancy)
      allow(ingestion).to receive(:party).and_return(nil)

      res2 = described_class.call(user: user, ingestion: ingestion)
      expect(res2).to be_failure
      expect(res2.failure.error).to include("Missing payer party")
    end

    it "handles Receipts::CreateService failure during confirmation" do
      ingestion = build_ingestion
      allow(Receipts::CreateService).to receive(:call).and_return(
        ServiceResult.failure(error: "Posting error", code: :posting_failed)
      )

      res = described_class.call(user: user, ingestion: ingestion)
      expect(res).to be_failure
      expect(res.failure.error).to eq("Posting error")
    end

    it "handles ActiveRecord::RecordNotFound gracefully" do
      ingestion = build_ingestion
      allow(Receipts::CreateService).to receive(:call).and_raise(ActiveRecord::RecordNotFound)

      res = described_class.call(user: user, ingestion: ingestion)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:not_found)
    end
  end
end

require "rails_helper"

RSpec.describe PaymentIngestion, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:party).optional }
    it { is_expected.to belong_to(:tenancy).optional }
    it { is_expected.to belong_to(:receipt).optional }
    it { is_expected.to belong_to(:payment_document).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:source) }
    it { is_expected.to validate_presence_of(:status) }

    describe "transaction number validation" do
      it { is_expected.to allow_value("TXN-123_abc").for(:transaction_number) }
      it { is_expected.not_to allow_value("TXN 123!").for(:transaction_number).with_message("must be alphanumeric with dashes or underscores") }
      it { is_expected.to validate_length_of(:transaction_number).is_at_most(50) }
    end

    context "with required fields" do
      it "is valid" do
        user = create(:user)
        ingestion = build(:payment_ingestion, user: user, source: "pdf_upload", status: "pending")
        expect(ingestion).to be_valid
      end
    end

    context "without required fields" do
      it "is invalid" do
        ingestion = PaymentIngestion.new(user: nil, source: nil, status: nil)
        expect(ingestion).not_to be_valid
      end
    end
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:status).with_values(
      pending: "pending",
      matched: "matched",
      unmatched: "unmatched",
      ambiguous: "ambiguous",
      confirmed: "confirmed",
      failed: "failed"
    ).backed_by_column_of_type(:string) }
  end

  describe "confirmable? and confirm! logic" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let(:ingestion) do
      build(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXN123"
      )
    end

    it "returns true for confirmable? when all fields are present and no duplicate exists" do
      expect(ingestion.confirmable?).to be_truthy
    end

    it "returns false for confirmable? when fields are missing" do
      ingestion.tenancy = nil
      expect(ingestion.confirmable?).to be_falsey
    end

    it "returns false for confirmable? when a duplicate payment receipt exists" do
      create(:receipt,
        user: user,
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 50_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "TXN123"
      )
      expect(ingestion.confirmable?).to be_falsey
    end

    it "confirm! creates receipt and updates status" do
      ingestion_to_confirm = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        transaction_number: "TXN456"
      )

      expect {
        receipt = ingestion_to_confirm.confirm!
        expect(receipt.amount).to eq(1200.0)
        expect(receipt.payment_method).to eq("venmo")
        expect(receipt.external_reference).to eq("TXN456")
        expect(receipt.tenancy).to eq(tenancy)
        expect(receipt.payer_party).to eq(party)
      }.to change(Receipt, :count).by(1)

      expect(ingestion_to_confirm.reload.status).to eq("confirmed")
      expect(ingestion_to_confirm.receipt).not_to be_nil
    end

    it "confirm! with create_alias: true creates alias" do
      alias_ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        payer_name: "Samantha Lopez",
        payer_username: "@samlopez",
        transaction_number: "TXN789"
      )

      expect {
        alias_ingestion.confirm!(create_alias: true)
      }.to change(PartyAlias, :count).by(2)

      expect(party.party_aliases.exists?(alias_name: "Samantha Lopez")).to be_truthy
      expect(party.party_aliases.exists?(alias_name: "@samlopez")).to be_truthy
    end

    it "confirm! returns existing receipt if called again on already confirmed ingestion" do
      confirmed_ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        transaction_number: "TXNIDEM"
      )

      first_receipt = confirmed_ingestion.confirm!
      expect {
        second_receipt = confirmed_ingestion.confirm!
        expect(second_receipt).to eq(first_receipt)
      }.not_to change(Receipt, :count)
    end
  end

  describe "duplicate scope verification" do
    let(:user_one) { create(:user) }
    let(:user_two) { create(:user) }
    let(:party_one) { create(:party, user: user_one) }
    let(:party_two) { create(:party, user: user_two) }
    let(:prop_one) { create(:property, user: user_one) }
    let(:prop_two) { create(:property, user: user_two) }
    let(:unit_one) { create(:rentable_unit, property: prop_one) }
    let(:unit_two) { create(:rentable_unit, property: prop_two) }
    let(:tenancy_one) { create(:tenancy, rentable_unit: unit_one) }
    let(:tenancy_two) { create(:tenancy, rentable_unit: unit_two) }

    it "only flags duplicates within the same user" do
      create(:receipt,
        user: user_two,
        tenancy: tenancy_two,
        payer_party: party_two,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "TXNSCOPED"
      )

      ingestion = build(:payment_ingestion,
        user: user_one,
        source: "pdf_upload",
        status: "matched",
        party: party_one,
        tenancy: tenancy_one,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNSCOPED"
      )

      expect(ingestion.duplicate_exists?).to be_falsey
      expect(ingestion).to be_valid

      # When receipt exists for user one with matching transaction number
      create(:receipt,
        tenancy: tenancy_one,
        user: user_one,
        payer_party: party_one,
        amount_cents: 100_000,
        received_on: Date.current,
        payment_method: "zelle",
        external_reference: "TXNSCOPED_MATCH"
      )
      ingestion.transaction_number = "TXNSCOPED_MATCH"

      expect(ingestion.duplicate_exists?).to be_truthy
      expect(ingestion).not_to be_valid
    end
  end

  describe "pessimistic locking" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "prevents race conditions and safely handles concurrent confirmations" do
      ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        transaction_number: "TXNRACE"
      )

      results = []
      threads = []

      2.times do
        threads << Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            results << PaymentIngestion.find(ingestion.id).confirm!
          end
        end
      end

      threads.each(&:join)

      expect(results.size).to eq(2)
      expect(results.first).to be_a(Receipt)
      expect(results.last).to be_a(Receipt)
      expect(results.first.id).to eq(results.last.id)
      expect(ingestion.reload.status).to eq("confirmed")
    end
  end

  describe "attachment presence checks" do
    let(:user) { create(:user) }

    it "supports database-backed attachment" do
      payment_doc = create(:payment_document,
        user: user,
        attachment_file: "fake receipt content",
        attachment_filename: "test.pdf",
        attachment_content_type: "application/pdf"
      )

      ingestion = build(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "pending",
        payment_document: payment_doc
      )

      expect(ingestion.save).to be_truthy
      expect(ingestion.attachment_attached?).to be_truthy
      expect(ingestion.payment_document.attachment_filename).to eq("test.pdf")
      expect(ingestion.payment_document.attachment_file).to eq("fake receipt content")
    end
  end

  describe "#attachment_image?" do
    let(:user) { create(:user) }

    it "returns true if attachment content type starts with image/" do
      doc = build(:payment_document, user: user, attachment_content_type: "image/png")
      ingestion = build(:payment_ingestion, user: user, payment_document: doc)
      expect(ingestion.attachment_image?).to be_truthy
    end

    it "returns false if attachment content type does not start with image/" do
      doc = build(:payment_document, user: user, attachment_content_type: "application/pdf")
      ingestion = build(:payment_ingestion, user: user, payment_document: doc)
      expect(ingestion.attachment_image?).to be_falsey
    end

    it "returns false/nil if payment_document is missing" do
      ingestion = build(:payment_ingestion, user: user, payment_document: nil)
      expect(ingestion.attachment_image?).to be_nil
    end
  end

  describe "parsing failure validation" do
    let(:user) { create(:user) }

    it "adds errors on base if parsing failed with error message and blank fields" do
      ingestion = build(:payment_ingestion, user: user, status: :failed, error_message: "Wrong header", amount: nil, party: nil)
      expect(ingestion).not_to be_valid
      expect(ingestion.errors[:base]).to include("Parsing failed: Wrong header")
    end
  end

  describe "confirm! create_alias edge cases" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user, display_name: "Samantha Lopez") }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }

    it "confirm! with create_alias: true does not create alias if username is not candidate" do
      alias_ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        party: party,
        tenancy: tenancy,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        payer_name: "Samantha Lopez Custom Alias",
        payer_username: "@samlopez",
        transaction_number: "TXN789"
      )

      create(:party_alias, party: party, alias_name: "@samlopez")

      expect {
        alias_ingestion.confirm!(create_alias: true)
      }.to change(PartyAlias, :count).by(1)

      expect(party.party_aliases.exists?(alias_name: "Samantha Lopez Custom Alias")).to be_truthy
    end

    it "returns the user via #accounting_user" do
      ingestion = build(:payment_ingestion, user: user)
      expect(ingestion.accounting_user).to eq(user)
    end
  end

  describe "immutability and undeletability after confirmation" do
    let(:user) { create(:user) }
    let(:party) { create(:party, user: user) }
    let(:property) { create(:property, user: user) }
    let(:unit) { create(:rentable_unit, property: property) }
    let(:tenancy) { create(:tenancy, rentable_unit: unit) }
    let!(:confirmed_ingestion) do
      create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "confirmed",
        party: party,
        tenancy: tenancy,
        amount: 1500.0,
        payment_date: Date.new(2026, 1, 15),
        payment_method: "zelle",
        transaction_number: "ZEL12345"
      )
    end

    it "prevents updating party_id on confirmed ingestion" do
      other_party = create(:party, user: user)
      confirmed_ingestion.party = other_party
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating amount on confirmed ingestion" do
      confirmed_ingestion.amount = 2000.0
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating payment_date on confirmed ingestion" do
      confirmed_ingestion.payment_date = Date.new(2026, 2, 1)
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating payment_method on confirmed ingestion" do
      confirmed_ingestion.payment_method = "venmo"
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating transaction_number on confirmed ingestion" do
      confirmed_ingestion.transaction_number = "NEW_TXN"
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents changing status from confirmed to matched" do
      confirmed_ingestion.status = :matched
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating raw_text on confirmed ingestion" do
      confirmed_ingestion.raw_text = "new parsed text"
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating payer_name on confirmed ingestion" do
      confirmed_ingestion.payer_name = "New Payer"
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents updating payment_document on confirmed ingestion" do
      other_doc = create(:payment_document, user: user)
      confirmed_ingestion.payment_document = other_doc
      expect(confirmed_ingestion).not_to be_valid
      expect(confirmed_ingestion.errors[:base]).to include("Cannot modify a confirmed payment ingestion")
    end

    it "prevents destroying a confirmed ingestion" do
      expect {
        confirmed_ingestion.destroy
      }.not_to change(PaymentIngestion, :count)

      expect(confirmed_ingestion.errors[:base]).to include("Cannot delete a confirmed payment ingestion")
    end
  end
end

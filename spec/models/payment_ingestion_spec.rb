require 'rails_helper'

RSpec.describe PaymentIngestion, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should belong_to(:tenant).optional }
    it { should belong_to(:lease).optional }
    it { should belong_to(:tenant_payment).optional }
    it { should belong_to(:payment_document).optional }
  end

  describe 'validations' do
    it { should validate_presence_of(:source) }
    it { should validate_presence_of(:status) }

    describe 'transaction number validation' do
      it { should allow_value('TXN-123_abc').for(:transaction_number) }
      it { should_not allow_value('TXN 123!').for(:transaction_number).with_message('must be alphanumeric with dashes or underscores') }
      it { should validate_length_of(:transaction_number).is_at_most(50) }
    end

    context 'with required fields' do
      it 'is valid' do
        user = create(:user)
        ingestion = build(:payment_ingestion, user: user, source: "pdf_upload", status: "pending")
        expect(ingestion).to be_valid
      end
    end

    context 'without required fields' do
      it 'is invalid' do
        ingestion = PaymentIngestion.new(user: nil, source: nil, status: nil)
        expect(ingestion).not_to be_valid
      end
    end
  end

  describe 'enums' do
    it { should define_enum_for(:status).with_values(
      pending: "pending",
      matched: "matched",
      unmatched: "unmatched",
      ambiguous: "ambiguous",
      confirmed: "confirmed",
      failed: "failed"
    ).backed_by_column_of_type(:string) }
  end

  describe 'confirmable? and confirm! logic' do
    let(:user) { create(:user) }
    let(:tenant) { create(:tenant, user: user) }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) { create(:lease, rental_property: property) }
    let(:ingestion) do
      build(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXN123"
      )
    end

    it 'returns true for confirmable? when all fields are present and no duplicate exists' do
      expect(ingestion.confirmable?).to be_truthy
    end

    it 'returns false for confirmable? when fields are missing' do
      ingestion.lease = nil
      expect(ingestion.confirmable?).to be_falsey
    end

    it 'returns false for confirmable? when a duplicate payment exists' do
      create(:tenant_payment,
        lease: lease,
        amount: 500.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXN123"
      )
      expect(ingestion.confirmable?).to be_falsey
    end

    it 'confirm! creates tenant payment and updates status' do
      ingestion_to_confirm = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        transaction_number: "TXN456"
      )

      expect {
        payment = ingestion_to_confirm.confirm!
        expect(payment.amount).to eq(1200.0)
        expect(payment.payment_method).to eq("venmo")
        expect(payment.transaction_number).to eq("TXN456")
        expect(payment.lease).to eq(lease)
      }.to change(TenantPayment, :count).by(1)

      expect(ingestion_to_confirm.reload.status).to eq("confirmed")
      expect(ingestion_to_confirm.tenant_payment).not_to be_nil
    end

    it 'confirm! with create_alias: true creates alias' do
      alias_ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        payer_name: "Samantha Lopez",
        payer_username: "@samlopez",
        transaction_number: "TXN789"
      )

      expect {
        alias_ingestion.confirm!(create_alias: true)
      }.to change(TenantAlias, :count).by(2)

      expect(tenant.tenant_aliases.exists?(alias_name: "Samantha Lopez")).to be_truthy
      expect(tenant.tenant_aliases.exists?(alias_name: "@samlopez")).to be_truthy
    end

    it 'confirm! rescues RecordNotUnique and raises ConfirmationError' do
      create(:tenant_payment,
        user: user,
        lease: lease,
        amount: 500.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNDUP"
      )

      dup_ingestion = build(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNDUP"
      )

      expect {
        dup_ingestion.confirm!
      }.to raise_error(PaymentIngestions::ConfirmationError)
    end

    it 'confirm! rescues RecordNotUnique and raises ConfirmationError when TenantPayment.create! raises RecordNotUnique' do
      allow(TenantPayment).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new("Duplicate key error"))
      expect {
        ingestion.confirm!
      }.to raise_error(PaymentIngestions::ConfirmationError, /This transaction has already been recorded/)
    end
  end

  describe 'duplicate scope verification' do
    let(:user_one) { create(:user) }
    let(:user_two) { create(:user) }
    let(:tenant_one) { create(:tenant, user: user_one) }
    let(:tenant_two) { create(:tenant, user: user_two) }
    let(:prop_one) { create(:rental_property, user: user_one) }
    let(:prop_two) { create(:rental_property, user: user_two) }
    let(:lease_one) { create(:lease, rental_property: prop_one) }
    let(:lease_two) { create(:lease, rental_property: prop_two) }

    it 'only flags duplicates within the same user' do
      create(:tenant_payment,
        lease: lease_two,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNSCOPED"
      )

      ingestion = build(:payment_ingestion,
        user: user_one,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant_one,
        lease: lease_one,
        amount: 1000.0,
        payment_date: Date.current,
        payment_method: "zelle",
        transaction_number: "TXNSCOPED"
      )

      expect(ingestion.duplicate_exists?).to be_falsey
      expect(ingestion).to be_valid

      # Reassign payment to user one
      payment = TenantPayment.find_by!(transaction_number: "TXNSCOPED")
      payment.update!(lease: lease_one, user: user_one)

      expect(ingestion.duplicate_exists?).to be_truthy
      expect(ingestion).not_to be_valid
    end
  end

  describe 'pessimistic locking' do
    let(:user) { create(:user) }
    let(:tenant) { create(:tenant, user: user) }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) { create(:lease, rental_property: property) }

    it 'prevents race conditions and raises already confirmed on concurrent calls' do
      ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        transaction_number: "TXNRACE"
      )

      exceptions = []
      threads = []

      2.times do
        threads << Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            begin
              # Reload to get separate in-memory status checking
              PaymentIngestion.find(ingestion.id).confirm!
            rescue => e
              exceptions << e
            end
          end
        end
      end

      threads.each(&:join)

      expect(exceptions.size).to eq(1)
      expect(exceptions.first).to be_a(PaymentIngestions::ConfirmationError)
      expect(exceptions.first.message).to match(/Already confirmed/)
      expect(ingestion.reload.status).to eq("confirmed")
    end
  end

  describe 'attachment presence checks' do
    let(:user) { create(:user) }

    it 'supports database-backed attachment' do
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

  describe '#attachment_image?' do
    let(:user) { create(:user) }

    it 'returns true if attachment content type starts with image/' do
      doc = build(:payment_document, user: user, attachment_content_type: 'image/png')
      ingestion = build(:payment_ingestion, user: user, payment_document: doc)
      expect(ingestion.attachment_image?).to be_truthy
    end

    it 'returns false if attachment content type does not start with image/' do
      doc = build(:payment_document, user: user, attachment_content_type: 'application/pdf')
      ingestion = build(:payment_ingestion, user: user, payment_document: doc)
      expect(ingestion.attachment_image?).to be_falsey
    end

    it 'returns false/nil if payment_document is missing' do
      ingestion = build(:payment_ingestion, user: user, payment_document: nil)
      expect(ingestion.attachment_image?).to be_nil
    end
  end

  describe 'parsing failure validation' do
    let(:user) { create(:user) }

    it 'adds errors on base if parsing failed with error message and blank fields' do
      ingestion = build(:payment_ingestion, user: user, status: :failed, error_message: "Wrong header", amount: nil, tenant: nil)
      expect(ingestion).not_to be_valid
      expect(ingestion.errors[:base]).to include("Parsing failed: Wrong header")
    end
  end

  describe 'confirm! create_alias edge cases' do
    let(:user) { create(:user) }
    let(:tenant) { create(:tenant, user: user, name: "Samantha Lopez") }
    let(:property) { create(:rental_property, user: user) }
    let(:lease) { create(:lease, rental_property: property) }

    it 'confirm! with create_alias: true does not create alias if username is not candidate' do
      alias_ingestion = create(:payment_ingestion,
        user: user,
        source: "pdf_upload",
        status: "matched",
        tenant: tenant,
        lease: lease,
        amount: 1200.0,
        payment_date: Date.current,
        payment_method: "venmo",
        payer_name: "Samantha Lopez Custom Alias", # candidate
        payer_username: "@samlopez", # candidate, but let's make it not candidate by creating it first
        transaction_number: "TXN789"
      )

      # Create alias for @samlopez first, so it is no longer an alias candidate
      create(:tenant_alias, tenant: tenant, alias_name: "@samlopez")

      expect {
        alias_ingestion.confirm!(create_alias: true)
      }.to change(TenantAlias, :count).by(1) # Only creates alias for payer_name

      expect(tenant.tenant_aliases.exists?(alias_name: "Samantha Lopez Custom Alias")).to be_truthy
    end
  end
end

require 'rails_helper'

RSpec.describe PaymentIngestionsHelper, type: :helper do
  describe '#payment_ingestion_alias_proposal' do
    let(:user) { create(:user) }
    let(:tenant) { create(:tenant, user: user, name: "Jane Smith") }

    it 'returns nil if tenant is nil' do
      ingestion = build(:payment_ingestion, user: user, tenant: nil)
      expect(helper.payment_ingestion_alias_proposal(ingestion)).to be_nil
    end

    it 'returns payer_name if it is an alias candidate' do
      ingestion = build(:payment_ingestion, user: user, tenant: tenant, payer_name: "Jane S. Smith", payer_username: nil)
      expect(helper.payment_ingestion_alias_proposal(ingestion)).to eq("Jane S. Smith")
    end

    it 'returns payer_username if payer_name is not candidate but payer_username is candidate' do
      # payer_name matches tenant name (so not candidate)
      ingestion = build(:payment_ingestion, user: user, tenant: tenant, payer_name: "Jane Smith", payer_username: "@janesmith")
      expect(helper.payment_ingestion_alias_proposal(ingestion)).to eq("@janesmith")
    end

    it 'returns nil if neither payer_name nor payer_username are candidates' do
      # Both match the existing name or are blank
      ingestion = build(:payment_ingestion, user: user, tenant: tenant, payer_name: "Jane Smith", payer_username: "")
      expect(helper.payment_ingestion_alias_proposal(ingestion)).to be_nil
    end
  end
end

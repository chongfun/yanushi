require 'rails_helper'

RSpec.describe Tenant, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should have_many(:lease_tenants).dependent(:destroy) }
    it { should have_many(:leases).through(:lease_tenants) }
    it { should have_many(:tenant_payments).through(:leases) }
    it { should have_many(:tenant_aliases).dependent(:destroy) }
    it { should have_many(:payment_ingestions).dependent(:nullify) }
  end

  describe 'validations' do
    it { should validate_presence_of(:name) }
  end

  describe '#alias_candidate?' do
    let(:user) { create(:user) }
    let(:tenant) { create(:tenant, user: user, name: "Jane Doe") }

    it 'returns false for blank values' do
      expect(tenant.alias_candidate?(nil)).to be_falsey
      expect(tenant.alias_candidate?("")).to be_falsey
      expect(tenant.alias_candidate?("   ")).to be_falsey
    end

    it 'returns false if it matches tenant name case-insensitively' do
      expect(tenant.alias_candidate?("Jane Doe")).to be_falsey
      expect(tenant.alias_candidate?("jane doe")).to be_falsey
      expect(tenant.alias_candidate?("  JANE DOE  ")).to be_falsey
    end

    it 'returns false if alias already exists' do
      tenant.tenant_aliases.create!(alias_name: "J. Doe")
      expect(tenant.alias_candidate?("J. Doe")).to be_falsey
      expect(tenant.alias_candidate?("j. doe")).to be_falsey
      expect(tenant.alias_candidate?("  J. DOE  ")).to be_falsey
    end

    it 'returns true for new unique aliases' do
      expect(tenant.alias_candidate?("Janey")).to be_truthy
      expect(tenant.alias_candidate?("Jane D.")).to be_truthy
    end

    it 'uses in-memory check if tenant_aliases association is loaded' do
      tenant.tenant_aliases.create!(alias_name: "J. Doe")
      tenant.tenant_aliases.load

      queries_count = 0
      callback = ->(*args) {
        event = ActiveSupport::Notifications::Event.new(*args)
        queries_count += 1 unless event.payload[:name] == 'SCHEMA' || event.payload[:sql] =~ /transaction|RELEASE|SAVEPOINT/i
      }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        expect(tenant.alias_candidate?("J. Doe")).to be_falsey
        expect(tenant.alias_candidate?("Jane D.")).to be_truthy
      end
      expect(queries_count).to eq(0)
    end
  end
end

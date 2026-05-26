require 'rails_helper'

RSpec.describe TenantAlias, type: :model do
  describe 'associations' do
    it { should belong_to(:tenant) }
  end

  describe 'validations' do
    subject { build(:tenant_alias) }
    it { should validate_presence_of(:alias_name) }
    it { should validate_uniqueness_of(:alias_name).scoped_to(:tenant_id).case_insensitive }
  end

  describe 'normalization' do
    it 'strips whitespace from alias_name' do
      tenant_alias = create(:tenant_alias, alias_name: "   Sam S   ")
      expect(tenant_alias.alias_name).to eq("Sam S")
    end
  end

  describe 'scoping behavior' do
    let(:user) { create(:user) }
    let(:tenant_one) { create(:tenant, user: user) }
    let(:tenant_two) { create(:tenant, user: user) }

    it 'enforces case-insensitive uniqueness scoped to tenant' do
      create(:tenant_alias, tenant: tenant_one, alias_name: "Sam S")

      # Same tenant, duplicate name -> invalid
      dup_same = build(:tenant_alias, tenant: tenant_one, alias_name: "sam s")
      expect(dup_same).not_to be_valid
      expect(dup_same.errors[:alias_name]).to include("has already been taken")

      # Different tenant, same name -> valid
      dup_diff = build(:tenant_alias, tenant: tenant_two, alias_name: "sam s")
      expect(dup_diff).to be_valid
    end
  end
end

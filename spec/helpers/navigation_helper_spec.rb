require "rails_helper"

RSpec.describe NavigationHelper, type: :helper do
  describe "PRIMARY_ITEMS" do
    it "defines the five primary user destinations" do
      expect(NavigationHelper::PRIMARY_ITEMS.map { |i| i[:key] }).to eq([
        :overview,
        :portfolio,
        :money,
        :inbox,
        :reports
      ])
    end
  end

  describe "#active_primary_navigation_key" do
    def set_path(path)
      allow(helper).to receive(:request).and_return(double(path: path))
    end

    it "maps / to :overview" do
      set_path("/")
      expect(helper.active_primary_navigation_key).to eq(:overview)
    end

    it "maps portfolio and related resources to :portfolio" do
      %w[
        /portfolio
        /properties
        /properties/123
        /tenancies
        /tenancies/456
        /parties
        /parties/789
        /rentable_units
        /rentable_units/10
      ].each do |path|
        set_path(path)
        expect(helper.active_primary_navigation_key).to eq(:portfolio), "expected #{path} to map to :portfolio"
      end
    end

    it "maps money and related resources to :money" do
      %w[
        /money
        /receipts
        /receipts/123
        /expenses
        /expenses/456
        /charges
        /charges/789
        /security_deposit_transactions
        /security_deposit_transactions/10
      ].each do |path|
        set_path(path)
        expect(helper.active_primary_navigation_key).to eq(:money), "expected #{path} to map to :money"
      end
    end

    it "maps inbox and related resources to :inbox" do
      %w[
        /inbox
        /imported_transactions
        /imported_transactions/123
        /source_documents
        /source_documents/456
      ].each do |path|
        set_path(path)
        expect(helper.active_primary_navigation_key).to eq(:inbox), "expected #{path} to map to :inbox"
      end
    end

    it "maps reports and property schedule_e routes to :reports" do
      %w[
        /reports
        /reports/2026
        /properties/123/schedule_e
        /properties/123/schedule_e_pdf
      ].each do |path|
        set_path(path)
        expect(helper.active_primary_navigation_key).to eq(:reports), "expected #{path} to map to :reports"
      end
    end

    it "maps accounts and journal entries to :accounting" do
      %w[
        /accounts
        /accounts/123
        /journal_entries
        /journal_entries/456
      ].each do |path|
        set_path(path)
        expect(helper.active_primary_navigation_key).to eq(:accounting), "expected #{path} to map to :accounting"
      end
    end

    it "returns nil for unmatched paths" do
      set_path("/some_unknown_path")
      expect(helper.active_primary_navigation_key).to be_nil
    end
  end

  describe "#primary_navigation_item_active?" do
    it "returns true when key matches active key" do
      allow(helper).to receive(:request).and_return(double(path: "/portfolio"))
      expect(helper.primary_navigation_item_active?(:portfolio)).to be true
      expect(helper.primary_navigation_item_active?("portfolio")).to be true
      expect(helper.primary_navigation_item_active?(:money)).to be false
    end
  end

  describe "#inbox_reviewable_count" do
    let(:user) { create(:user) }

    after do
      Current.session = nil
    end

    it "returns 0 when there is no Current.user" do
      Current.session = nil
      expect(helper.inbox_reviewable_count).to eq(0)
    end

    it "returns count of reviewable imported transactions for Current.user" do
      Current.session = create(:session, user: user)
      source_doc = create(:source_document, user: user)
      create(:imported_transaction, :unmatched, user: user, source_document: source_doc)
      create(:imported_transaction, :matched, user: user, source_document: source_doc)
      create(:imported_transaction, :confirmed_receipt, user: user, source_document: source_doc)

      expect(helper.inbox_reviewable_count).to eq(2)
    end

    it "memoizes the count so multiple calls in one render only query once" do
      Current.session = create(:session, user: user)
      source_doc = create(:source_document, user: user)
      create(:imported_transaction, :unmatched, user: user, source_document: source_doc)

      queries = []
      callback = lambda { |_name, _start, _finish, _id, payload|
        queries << payload[:sql] if payload[:sql].match?(/COUNT\(/i)
      }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        3.times { helper.inbox_reviewable_count }
      end

      expect(queries.size).to eq(1)
    end
  end
end

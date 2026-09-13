require "rails_helper"

RSpec.describe ImportedTransactions::InboxBroadcastService do
  let(:user) { create(:user) }

  describe ".call" do
    it "broadcasts replacement of inbox_processing_view and inbox_review_empty without prepending to active queue when new review items arrive" do
      doc = create(:source_document, user: user, status: "success")
      create(:imported_transaction, user: user, source_document: doc, status: "unmatched")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          review_count: 1,
          processing_count: 0,
          failed_count: 0,
          inbox_revision: an_instance_of(Integer)
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "broadcasts removal of deleted document row and cascaded transactions when deleted_document_id is provided" do
      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          deleted_document_id: 42,
          deleted_transaction_ids: [ 101 ],
          review_count: 0
        )
      )

      described_class.call(
        user: user,
        deleted_document_id: 42,
        deleted_transaction_ids: [ 101 ]
      )
    end

    it "broadcasts replacement of inbox_review_empty with caught-up when successful document yields 0 reviewable items (duplicate import)" do
      doc = create(:source_document, user: user, status: "success")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: doc,
          review_count: 0,
          processing_count: 0,
          failed_count: 0
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "broadcasts replacement of inbox_processing_view when a document fails" do
      doc = create(:source_document, user: user, status: "failed", error_message: "Corrupted PDF")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: doc,
          review_count: 0,
          failed_count: 1,
          failed_documents: [ doc ]
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "broadcasts replacement of inbox_processing_view when a document is retried" do
      doc = create(:source_document, user: user, status: "processing")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: doc,
          processing_count: 1,
          processing_documents: [ doc ]
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "broadcasts badge and tab counts without document target when document is nil" do
      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: nil,
          review_count: 0,
          processing_count: 0,
          failed_count: 0
        )
      )

      described_class.call(user: user, document: nil)
    end

    it "removes only the completed document row without replacing processing view when other processing documents remain" do
      doc = create(:source_document, user: user, status: "success")
      _remaining_doc = create(:source_document, user: user, status: "processing")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: doc,
          processing_count: 1,
          failed_count: 0
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "removes only the completed document row without replacing processing view when failed documents remain" do
      doc = create(:source_document, user: user, status: "success")
      _failed_doc = create(:source_document, user: user, status: "failed", error_message: "Parse error")

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          document: doc,
          processing_count: 0,
          failed_count: 1
        )
      )

      described_class.call(user: user, document: doc)
    end

    it "broadcasts replacement for updated_transaction row fetched within snapshot when updated_transaction_id is provided" do
      doc = create(:source_document, user: user, status: "success")
      txn = create(:imported_transaction, user: user, source_document: doc, status: "matched", amount_cents: 100_000)

      expect(Turbo::StreamsChannel).to receive(:broadcast_render_to).with(
        [ user, :inbox ],
        partial: "imported_transactions/inbox_broadcast",
        locals: hash_including(
          updated_transaction: txn
        )
      )

      described_class.call(user: user, updated_transaction_id: txn.id)
    end

    it "prevents older delayed broadcasts from stamping a newer revision with a stale row snapshot" do
      doc = create(:source_document, user: user, status: "success")
      txn = create(:imported_transaction, user: user, source_document: doc, status: "matched", amount_cents: 100_000)

      # Save A commits $1,500
      txn.update!(amount_cents: 150_000)
      user.increment_inbox_revision!
      delayed_broadcast_caller = -> { described_class.call(user: user, updated_transaction_id: txn.id) }

      # Save B commits $2,000 before Save A's delayed broadcast runs
      txn.update!(amount_cents: 200_000)
      user.increment_inbox_revision!

      # When Save A's broadcast runs, it fetches the transaction inside the snapshot at current revision
      captured_locals = nil
      allow(Turbo::StreamsChannel).to receive(:broadcast_render_to) do |_target, options|
        captured_locals = options[:locals]
      end

      delayed_broadcast_caller.call

      expect(captured_locals[:updated_transaction].amount_cents).to eq(200_000)
      expect(captured_locals[:inbox_revision]).to eq(user.inbox_revision)
    end

    it "renders the inbox_broadcast template containing atomic streams for badges, sync target, and views" do
      doc = create(:source_document, user: user, status: "failed", error_message: "Bad format")
      txn = create(:imported_transaction, user: user, source_document: doc, status: "unmatched")
      html = ApplicationController.render(
        partial: "imported_transactions/inbox_broadcast",
        locals: {
          user: user,
          document: doc,
          deleted_document_id: nil,
          deleted_transaction_ids: [],
          updated_transaction: txn,
          review_count: 0,
          processing_count: 0,
          failed_count: 1,
          inbox_revision: 5,
          history_count: 2,
          reviewable_transactions: [],
          form_data: nil,
          processing_documents: [],
          failed_documents: [ doc ]
        }
      )

      expect(html).to include('target="inbox_processing_view"')
      expect(html).to include('target="inbox_review_workspace"')
      expect(html).to include('target="inbox_review_empty"')
      expect(html).to include("imported_transaction_#{txn.id}")
      expect(html).to include('target="sidebar_inbox_badge"')
      expect(html).to include('target="drawer_inbox_badge"')
      expect(html).to include('target="mobile_inbox_badge"')
      expect(html).to include('target="tab_review_count"')
      expect(html).to include('target="tab_processing_count"')
      expect(html).to include('target="tab_history_count"')
      expect(html).to include('target="inbox_sync"')
      expect(html).to include('data-inbox-sync-revision-value="5"')
    end
  end
end

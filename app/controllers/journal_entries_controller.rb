class JournalEntriesController < ApplicationController
  def show
    @journal_entry = authenticated_user.journal_entries
      .includes(postings: [ :account, :property, :rentable_unit, :tenancy, :party ], source: {}, reversal_of: :source, reversal: :source)
      .find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end

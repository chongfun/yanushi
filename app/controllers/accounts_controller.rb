class AccountsController < ApplicationController
  before_action :set_account, only: :show

  def index
    @accounts = authenticated_user.accounts.order(:account_type, :key)
    raw_sums = Posting.joins(:journal_entry)
                      .where(account_id: @accounts.map(&:id))
                      .where("journal_entries.occurred_on <= ?", Date.current)
                      .group(:account_id)
                      .sum(:amount_cents)
    balances = {} # : Hash[Integer, Integer]
    @accounts.each do |acc|
      balances[acc.id] = Accounting::NaturalBalance.convert(acc, raw_sums[acc.id] || 0)
    end
    @balances = balances
  end

  def show
    @date_range = Accounting::DateRange.parse(params)
    @properties = authenticated_user.properties.order(:address)
    @tenancies = authenticated_user.tenancies.includes(:property, :rentable_unit).order("properties.address ASC, tenancies.id DESC")

    if params[:property_id].present?
      @selected_property = authenticated_user.properties.find_by(id: params[:property_id])
      return head :not_found if @selected_property.nil?
    end

    if params[:tenancy_id].present?
      @selected_tenancy = authenticated_user.tenancies.find_by(id: params[:tenancy_id])
      return head :not_found if @selected_tenancy.nil?
    end

    if @selected_property && @selected_tenancy
      sel_prop = @selected_property
      sel_ten = @selected_tenancy
      if sel_prop && sel_ten && sel_ten.property&.id != sel_prop.id
        return head :not_found
      end
    end

    unless @date_range.valid?
      flash.now[:alert] = @date_range.errors.to_sentence
    end

    @activity_result = Accounting::AccountActivityQuery.call(
      account: @account,
      date_range: @date_range,
      property: @selected_property,
      tenancy: @selected_tenancy
    )
  end

  private

    def set_account
      @account = authenticated_user.accounts.find(params.expect(:id))
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end
end

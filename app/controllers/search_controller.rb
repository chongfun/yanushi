class SearchController < ApplicationController
  # The query lives in `?q=`, so a result page is shareable and survives a
  # refresh. Search is a tool, not an area: it has no primary navigation item.
  def show
    @min_query_length = Search::PortfolioQuery::MIN_QUERY_LENGTH
    @query = params[:q].to_s.strip
    @result = if @query.length >= @min_query_length
      Search::PortfolioQuery.call(user: authenticated_user, query: @query)
    end
  end
end

require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @intro_user = users(:intro_user)
    @family = @user.family
  end

  test "dashboard" do
    get root_path
    assert_response :ok
  end

  test "inactive user's existing session is revoked" do
    session_record = @user.sessions.order(:created_at).last
    @user.update_column(:active, false)

    get root_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(session_record.id)
  end

  test "update_preferences persists dashboard section layout height" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { net_worth_chart: { height: "compact" } } }
    }, as: :json

    assert_response :ok
    assert_equal "compact", @user.reload.dashboard_section_height("net_worth_chart")
  end

  test "update_preferences persists dashboard section width" do
    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: { cashflow_sankey: { col_span: "single" } } }
    }, as: :json

    assert_response :ok
    assert_equal "single", @user.reload.dashboard_section_width("cashflow_sankey")
  end

  test "update_preferences ignores malformed dashboard_section_layout without erroring" do
    previous_height = @user.reload.dashboard_section_height("net_worth_chart")

    patch "/dashboard/preferences", params: {
      preferences: { dashboard_section_layout: "not-a-hash" }
    }, as: :json

    assert_response :ok
    assert_equal previous_height, @user.reload.dashboard_section_height("net_worth_chart")
  end

  test "dashboard memoizes income statement period totals while rendering" do
    income_statement = IncomeStatement.new(@family)
    IncomeStatement.stubs(:new).returns(income_statement)

    fake_expense_period_total = IncomeStatement::PeriodTotal.new(
      classification: "expense",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    fake_income_period_total = IncomeStatement::PeriodTotal.new(
      classification: "income",
      total: 0,
      currency: @family.currency,
      category_totals: []
    )

    income_statement.expects(:build_period_total)
      .with(classification: "expense", period: kind_of(Period))
      .once
      .returns(fake_expense_period_total)

    income_statement.expects(:build_period_total)
      .with(classification: "income", period: kind_of(Period))
      .once
      .returns(fake_income_period_total)

    get root_path

    assert_response :ok
  end

  test "intro page requires guest role" do
    get intro_path

    assert_redirected_to root_path
    assert_equal "Intro is only available to guest users.", flash[:alert]
  end

  test "intro page is accessible for guest users" do
    sign_in @intro_user

    get intro_path

    assert_response :ok
  end

  test "dashboard renders sankey chart with subcategories" do
    # Create parent category with subcategory
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path
    assert_response :ok
    assert_select "[data-controller='sankey-chart']"
  end

  test "dashboard renders sankey chart zoom controls and stable node ids" do
    parent_category = @family.categories.create!(name: "Shopping", color: "#FF5733")
    subcategory = @family.categories.create!(name: "Groceries", parent: parent_category, color: "#33FF57")

    create_transaction(account: @family.accounts.first, name: "General shopping", amount: 100, category: parent_category)
    create_transaction(account: @family.accounts.first, name: "Grocery store", amount: 50, category: subcategory)

    get root_path

    assert_response :ok
    assert_select "[data-sankey-chart-target='zoomOutButton'][hidden]", count: 2

    chart = css_select("[data-controller='sankey-chart']").first
    sankey_data = JSON.parse(chart["data-sankey-chart-data-value"])

    assert_includes sankey_data.fetch("nodes").map { |node| node.fetch("id") }, "cash_flow_node"
    assert sankey_data.fetch("nodes").any? { |node| node.fetch("id").start_with?("expense_") }
  end

  test "outflows list shows net subcategories and direct spending without duplicating the donut total" do
    shopping = @family.categories.create!(name: "Shopping", color: "#3b82f6")
    amazon = @family.categories.create!(name: "Amazon", parent: shopping)
    account = @family.accounts.first
    create_transaction(account: account, amount: 100, category: shopping)
    create_transaction(account: account, amount: 50, category: amazon)
    create_transaction(account: account, amount: -20, category: amazon)
    pending = create_transaction(account: account, amount: 500, category: amazon)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    get root_path

    assert_response :ok
    assert_select "details[data-outflow-category-id=?][open]", shopping.id do
      assert_select "summary", text: /Shopping.*\$130\.00/
      assert_select "a[data-outflow-subcategory-id=?]", amazon.id, text: /Amazon.*\$30\.00/
      assert_select "[data-outflow-direct-category=?]", shopping.id, text: /Shopping \(no subcategory\).*\$100\.00/
    end

    segments = outflow_segments
    shopping_segment = segments.find { |segment| segment.fetch("id") == shopping.id }
    assert_equal 130.0, shopping_segment.fetch("amount")
    assert_equal 130.0, shopping_segment.fetch("subcategories").sum { |subcategory| subcategory.fetch("amount") }
    assert_not segments.any? { |segment| segment.fetch("id") == amazon.id }

    href = css_select("a[data-outflow-subcategory-id='#{amazon.id}']").first["href"]
    filters = Rack::Utils.parse_nested_query(URI.parse(href).query).fetch("q")
    assert_equal [ "Amazon" ], filters.fetch("categories")
    assert_equal [ "confirmed" ], filters.fetch("status")
    assert filters.fetch("start_date").present?
    assert filters.fetch("end_date").present?
  end

  test "outflows list accounts for refund-only subcategories as negative amounts" do
    shopping = @family.categories.create!(name: "Shopping", color: "#3b82f6")
    amazon = @family.categories.create!(name: "Amazon", parent: shopping)
    costco = @family.categories.create!(name: "Costco", parent: shopping)
    account = @family.accounts.first
    create_transaction(account: account, amount: 100, category: shopping)
    create_transaction(account: account, amount: 50, category: amazon)
    create_transaction(account: account, amount: -20, category: costco)

    get root_path

    assert_response :ok
    shopping_segment = outflow_segments.find { |segment| segment.fetch("id") == shopping.id }
    children = shopping_segment.fetch("subcategories")
    assert_equal 130.0, shopping_segment.fetch("amount")
    assert_equal(-20.0, children.find { |subcategory| subcategory.fetch("id") == costco.id }.fetch("amount"))
    assert_equal 130.0, children.sum { |subcategory| subcategory.fetch("amount") }
    assert_select "a[data-outflow-subcategory-id=?]", costco.id, text: /Costco.*-\$20\.00/
  end

  test "outflows list omits a zero direct remainder and keeps leaf category links" do
    shopping = @family.categories.create!(name: "Shopping", color: "#3b82f6")
    amazon = @family.categories.create!(name: "Amazon", parent: shopping)
    empty_child = @family.categories.create!(name: "Empty retailer", parent: shopping)
    leaf = @family.categories.create!(name: "Home Improvement", color: "#d97706")
    account = @family.accounts.first
    create_transaction(account: account, amount: 50, category: amazon)
    create_transaction(account: account, amount: 25, category: leaf)

    get root_path

    assert_response :ok
    assert_select "details[data-outflow-category-id=?]", shopping.id
    assert_select "[data-outflow-direct-category=?]", shopping.id, count: 0
    assert_select "a[data-outflow-subcategory-id=?]", empty_child.id, count: 0
    assert_select "#outflows-donut-section a[data-category-id=?]", leaf.id
  end

  test "dashboard renders money flow widget" do
    get root_path

    assert_response :ok
    assert_select "[data-controller='bar-chart']"
  end

  test "dashboard scopes money flow widget to selected month and accounts" do
    # Dedicated account (rather than @family.accounts.first) so fixture
    # transactions on other accounts can't skew the computed totals.
    account = @family.accounts.create!(name: "Money Flow Test Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    selected_month = 1.month.ago.beginning_of_month.to_date
    create_transaction(account: account, name: "Groceries", amount: 50, date: selected_month + 1.day)
    create_transaction(account: account, name: "Paycheck", amount: -200, date: selected_month + 2.days)

    get root_path, params: {
      money_flow_month: selected_month.iso8601,
      money_flow_account_ids: [ account.id ]
    }

    assert_response :ok
    bars = money_flow_bars

    assert_equal 6, bars.size
    highlighted = bars.find { |bar| bar["highlighted"] }
    assert_equal selected_month.iso8601, highlighted["date"]
    assert_equal 50.0, highlighted["expense"]
    assert_equal 200.0, highlighted["income"]
  end

  test "dashboard money flow widget ignores account ids not accessible to the current user" do
    other_family = Family.create!(name: "Other Family", currency: "USD")
    other_account = other_family.accounts.create!(name: "Other Family Checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: other_account, name: "Not mine", amount: 999)

    get root_path
    default_bars = money_flow_bars

    get root_path, params: { money_flow_account_ids: [ other_account.id ] }

    assert_response :ok
    filtered_bars = money_flow_bars

    # An id outside the current user's accessible accounts is dropped entirely
    # (money_flow_account_ids_param intersects against accessible ids), so the
    # widget falls back to its unfiltered "all accessible accounts" state
    # rather than scoping to a foreign account or erroring.
    assert_equal default_bars, filtered_bars
  end

  test "dashboard money flow widget excludes accounts ineligible for cashflow totals from its account filter" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )

    get root_path

    assert_response :ok
    assert_select "input[type='checkbox'][value=?]", excluded_account.id.to_s, count: 0
  end

  test "dashboard money flow widget ignores account ids excluded from cashflow totals" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )
    create_transaction(account: excluded_account, name: "Not counted", amount: 999)

    get root_path
    default_bars = money_flow_bars

    get root_path, params: { money_flow_account_ids: [ excluded_account.id ] }

    assert_response :ok
    filtered_bars = money_flow_bars

    # An account excluded from reports is visible/accessible but not eligible
    # for cashflow totals, so selecting only it must fall back to the
    # unfiltered state instead of silently computing to zero.
    assert_equal default_bars, filtered_bars
  end

  test "dashboard clamps a future money flow month instead of erroring" do
    get root_path, params: { money_flow_month: 1.month.from_now.beginning_of_month.iso8601 }

    assert_response :ok
    bars = money_flow_bars

    assert_equal Date.current.beginning_of_month.iso8601, bars.last["date"]
  end

  test "dashboard money flow income/expense links exclude pending transactions" do
    get root_path

    assert_response :ok
    assert_select "a[href*='q%5Btypes%5D%5B%5D=income'][href*='q%5Bstatus%5D%5B%5D=confirmed']"
    assert_select "a[href*='q%5Btypes%5D%5B%5D=expense'][href*='q%5Bstatus%5D%5B%5D=confirmed']"
  end

  test "dashboard money flow income/expense links stay scoped to eligible accounts by default" do
    excluded_account = @family.accounts.create!(
      name: "Excluded From Reports",
      currency: @family.currency,
      balance: 0,
      exclude_from_reports: true,
      accountable: Depository.new
    )

    get root_path

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # The default (unfiltered) state must still pin the drill-down links to
    # the eligible accounts backing the displayed totals, not the broader
    # accessible-accounts set transactions_path defaults to when account_ids
    # is absent.
    assert_includes income_href, "q%5Baccount_ids%5D%5B%5D="
    assert_not_includes income_href, excluded_account.id.to_s
    assert_includes expense_href, "q%5Baccount_ids%5D%5B%5D="
    assert_not_includes expense_href, excluded_account.id.to_s
  end

  test "dashboard money flow income/expense links omit account_ids when the default selection matches all accessible accounts" do
    # Plain @family fixture: every account is owned outright by family_admin,
    # none excluded from reports or tax-advantaged, so the widget's eligible
    # accounts exactly match Current.user.accessible_accounts (see #2955).
    get root_path

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # With nothing to scope down from the transactions page's own default,
    # the link should skip enumerating every account id so the URL stays
    # short (long q[account_ids][] lists break forward-auth proxies in front
    # of self-hosted deployments, see #2955).
    assert_not_includes income_href, "q%5Baccount_ids%5D"
    assert_not_includes expense_href, "q%5Baccount_ids%5D"
  end

  test "dashboard money flow income/expense links keep account_ids when a subset of accounts is explicitly selected" do
    account = @family.accounts.first

    get root_path, params: { money_flow_account_ids: [ account.id ] }

    assert_response :ok
    income_href = css_select("a[href*='q%5Btypes%5D%5B%5D=income']").first["href"]
    expense_href = css_select("a[href*='q%5Btypes%5D%5B%5D=expense']").first["href"]

    # A deliberate, narrower selection never matches the full
    # accessible-accounts set, so the links must keep scoping to it instead
    # of silently falling back to "all accounts".
    assert_includes income_href, "q%5Baccount_ids%5D%5B%5D=#{account.id}"
    assert_includes expense_href, "q%5Baccount_ids%5D%5B%5D=#{account.id}"

    account_filter = "q%5Baccount_ids%5D%5B%5D="
    assert_equal 1, income_href.scan(account_filter).length
    assert_equal 1, expense_href.scan(account_filter).length
  end

  test "changelog" do
    VCR.use_cassette("git_repository_provider/fetch_latest_release_notes") do
      get changelog_path
      assert_response :ok
      assert_select "[data-breadcrumbs]", text: /What's new/
    end
  end

  test "changelog with nil release notes" do
    # Mock the GitHub provider to return nil (simulating API failure or no releases)
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Release notes unavailable"
    assert_select "a[href='https://github.com/we-promise/sure/releases']"
  end

  test "changelog with incomplete release notes" do
    # Mock the GitHub provider to return incomplete data (missing some fields)
    github_provider = mock
    incomplete_data = {
      avatar: nil,
      username: "maybe-finance",
      name: "Test Release",
      published_at: nil,
      body: nil
    }
    github_provider.expects(:fetch_latest_release_notes).returns(incomplete_data)
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get changelog_path
    assert_response :ok
    assert_select "h2", text: "Test Release"
    # Should not crash even with nil values
  end

  test "feedback" do
    get feedback_path
    assert_response :ok
    assert_select "[data-breadcrumbs]", text: /Feedback/
  end

  private
    def outflow_segments
      JSON.parse(css_select("[data-controller='donut-chart']").first["data-donut-chart-segments-value"])
    end

    def money_flow_bars
      JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
    end
end

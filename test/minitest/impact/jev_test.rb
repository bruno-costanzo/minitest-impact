# frozen_string_literal: true

require "test_helper"

class JevTest < Minitest::Test
  URL = "https://api.typesafe.ai/v1/systemone"

  def client = Minitest::Impact::Jev::Client.new(api_key: "k", sleeper: ->(_seconds) {})

  def answer(answers, model: "jev-1.13.0")
    { status: 200, body: { model: model, answers: answers, usage: { input_tokens: 120, output_tokens: 9 } }.to_json }
  end

  def test_client_sends_the_pinned_model_state_and_questions_in_one_request
    stub = stub_request(:post, URL)
           .with(headers: { "Authorization" => "Bearer k" }) { |request| JSON.parse(request.body)["model"] == "jev-1.13.0" }
           .to_return(answer({ "q" => { "type" => "noul", "noul" => 0.9 } }))

    response = client.ask(state: { a: 1 }, questions: { q: { type: "noul", instructions: "?" } })

    assert_requested stub, times: 1
    assert_in_delta 0.9, response.answers["q"]["noul"]
    assert_equal 120, response.input_tokens
  end

  def test_client_retries_when_rate_limited_then_gives_up_with_a_failure
    stub_request(:post, URL).to_return({ status: 429, headers: { "retry-after" => "1" } }, answer({}))
    assert_equal({}, client.ask(state: "s", questions: {}).answers)

    stub_request(:post, URL).to_return(status: 529)
    assert_raises(Minitest::Impact::Jev::Client::Failure) { client.ask(state: "s", questions: {}) }

    stub_request(:post, URL).to_return(status: 200, body: "nope")
    assert_raises(Minitest::Impact::Jev::Client::Failure) { client.ask(state: "s", questions: {}) }

    stub_request(:post, URL).to_timeout
    assert_raises(Minitest::Impact::Jev::Client::Failure) { client.ask(state: "s", questions: {}) }
  end

  def test_client_reads_its_key_base_url_and_model_from_the_environment
    assert_nil Minitest::Impact::Jev::Client.from_env({})
    configured = Minitest::Impact::Jev::Client.from_env("TYPESAFE_API_KEY" => "k", "MINITEST_IMPACT_JEV_MODEL" => "jev-1.14.0")
    assert_equal "jev-1.14.0", configured.model
  end

  def test_ranker_keeps_every_pick_adds_new_ones_and_puts_the_most_direct_first
    sandbox.write("test/a_test.rb", "test \"invoice total\" do\nend\n")
    sandbox.write("test/b_test.rb", "test \"b\" do\nend\n")
    sandbox.write("test/invoice_pdf_test.rb", "test \"invoice pdf\" do\nend\n")
    sandbox.commit
    map = map_with(nil, "test/a_test.rb" => {}, "test/b_test.rb" => {}, "test/invoice_pdf_test.rb" => {})
    picks = [
      Minitest::Impact::Pick.new(test: "test/a_test.rb", score: 1.0, reasons: ["runs Invoice#total"], seconds: 1.0),
      Minitest::Impact::Pick.new(test: "test/b_test.rb", score: 0.4, reasons: ["loads x"], seconds: 1.0)
    ]
    change = Minitest::Impact::ChangedFile.new(path: "app/models/invoice.rb", status: :modified, old_lines: [1], new_lines: [1],
                                               added_text: "invoice pdf\n", removed_text: "")
    stub = stub_request(:post, URL).with { |request| JSON.parse(request.body)["questions"].key?("most_direct") }.to_return(answer({
      "t0" => { "noul" => 0.2 }, "t1" => { "noul" => 0.1 }, "t2" => { "noul" => 0.8 },
      "most_direct" => { "choice" => "t2", "confidence" => 0.7 }, "whole_suite" => { "noul" => 0.1 }
    }))

    ranked, report = Minitest::Impact::Jev::Ranker.new(client: client)
                                                  .call(picks: picks, changes: [change], intent: "pdf", repo: sandbox.repo, map: map, head: nil)

    assert_requested stub, times: 1
    assert_equal ["test/invoice_pdf_test.rb", "test/a_test.rb", "test/b_test.rb"], ranked.map(&:test)
    assert_equal({ "model" => "jev-1.13.0", "input_tokens" => 120, "candidates" => 3, "whole_suite" => false }, report)
  end

  def test_ranker_leaves_the_selection_alone_when_jev_fails
    sandbox.write("test/a_test.rb", "x\n")
    sandbox.commit
    picks = [Minitest::Impact::Pick.new(test: "test/a_test.rb", score: 0.5, reasons: [], seconds: nil)]
    stub_request(:post, URL).to_return(status: 401, body: "bad key")

    ranked, report = Minitest::Impact::Jev::Ranker.new(client: client)
                                                  .call(picks: picks, changes: [], intent: nil, repo: sandbox.repo, map: map_with(nil, {}), head: nil)

    assert_equal picks, ranked
    assert_match(/401/, report["error"])
  end

  def test_selector_asks_jev_only_when_the_map_is_not_enough
    sandbox.write("lib/a.rb", "class A\n  def x\n    1\n  end\nend\n")
    sandbox.write("test/a_test.rb", "test \"a\" do\nend\n")
    base = sandbox.commit
    map = map_with(base, "test/a_test.rb" => { "lib/a.rb" => [3] })
    ranker = Minitest::Impact::Jev::Ranker.new(client: client)
    File.write(File.join(sandbox.root, "lib/a.rb"), "class A\n  def x\n    2\n  end\nend\n")

    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base, ranker: ranker).call
    assert_nil selection.jev

    File.write(File.join(sandbox.root, "config.json"), "{}")
    stub_request(:post, URL).to_return(answer({ "t0" => { "noul" => 0.9 }, "whole_suite" => { "noul" => 0.95 } }))
    selection = Minitest::Impact::Selector.new(repo: sandbox.repo, map: map, base: base, ranker: ranker).call
    assert selection.whole_suite
    assert_equal ["test/a_test.rb"], selection.tests
  end
end

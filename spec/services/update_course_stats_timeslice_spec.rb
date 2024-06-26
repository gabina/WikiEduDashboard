# frozen_string_literal: true

require 'rails_helper'

describe UpdateCourseStatsTimeslice do
  let(:course) { create(:course, flags:) }
  let(:enwiki) { Wiki.get_or_create(language: 'en', project: 'wikipedia') }
  let(:wikidata) { Wiki.get_or_create(language: nil, project: 'wikidata') }
  let(:subject) { described_class.new(course, enwiki, '20181124000000', '20181129190000') }

  context 'when debugging is not enabled' do
    let(:flags) { nil }

    it 'posts no Sentry logs' do
      expect(Sentry).not_to receive(:capture_message)
      subject
    end
  end

  context 'when :debug_updates flag is set' do
    let(:flags) { { debug_updates: true } }

    it 'posts debug info to Sentry' do
      expect(Sentry).to receive(:capture_message).at_least(6).times.and_call_original
      subject
    end
  end

  context 'when there are revisions' do
    let(:course) { create(:course, start: '2018-11-23', end: '2018-11-30') }
    let(:user) { create(:user, username: 'Ragesoss') }

    before do
      stub_wiki_validation
      course.campaigns << Campaign.first
      course.wikis << Wiki.get_or_create(language: nil, project: 'wikidata')
      JoinCourse.new(course:, user:, role: 0)
      VCR.use_cassette 'course_update' do
        subject
      end
    end

    it 'imports average views of edited articles' do
      # 2 en.wiki articles
      expect(course.articles.where(wiki: enwiki).count).to eq(2)
      # 13 wikidata articles
      expect(course.articles.where(wiki: wikidata).count).to eq(13)
      # TODO: fix this. Right now doesn't work because ArticleCourses records
      # were not created for the time AverageViewsImporter.update_outdated_average_views runs
      # expect(course.articles.where(wiki: enwiki).last.average_views).to be > 0
    end

    it 'updates article course and article course timeslices caches' do
      # Check caches for mw_page_id 6901525
      article = Article.find_by(mw_page_id: 6901525)
      # The article course exists
      article_course = ArticlesCourses.find_by(article_id: article.id)
      # The article course caches were updated
      expect(article_course.character_sum).to eq(427)
      expect(article_course.references_count).to eq(-2)
      expect(article_course.user_ids).to eq([user.id])

      # Article course timeslice record was created for mw_page_id 6901525
      expect(article_course.article_course_timeslices.count).to eq(1)
      # Article course timeslices caches were updated
      expect(article_course.article_course_timeslices.first.character_sum).to eq(427)
      expect(article_course.article_course_timeslices.first.references_count).to eq(-2)
      expect(article_course.article_course_timeslices.first.user_ids).to eq([user.id])
    end
  end

  context 'sentry course update error tracking' do
    let(:flags) { { debug_updates: true } }
    let(:user) { create(:user, username: 'Ragesoss') }

    before do
      create(:courses_user, course_id: course.id, user_id: user.id)
    end

    it 'tracks update errors properly in Replica' do
      allow(Sentry).to receive(:capture_exception)

      # Raising errors only in Replica
      stub_request(:any, %r{https://dashboard-replica-endpoint.wmcloud.org/.*}).to_raise(Errno::ECONNREFUSED)
      VCR.use_cassette 'course_update/replica' do
        subject
      end
      sentry_tag_uuid = subject.sentry_tag_uuid
      expect(course.flags['update_logs'][1]['error_count']).to eq 1
      expect(course.flags['update_logs'][1]['sentry_tag_uuid']).to eq sentry_tag_uuid

      # Checking whether Sentry receives correct error and tags as arguments
      expect(Sentry).to have_received(:capture_exception).once.with(Errno::ECONNREFUSED, anything)
      expect(Sentry).to have_received(:capture_exception)
        .once.with anything, hash_including(tags: { update_service_id: sentry_tag_uuid,
                                                    course: course.slug })
    end

    it 'tracks update errors properly in LiftWing' do
      allow(Sentry).to receive(:capture_exception)

      # Raising errors only in LiftWing
      stub_request(:any, %r{https://api.wikimedia.org/service/lw.*}).to_raise(Faraday::ConnectionFailed)
      VCR.use_cassette 'course_update/lift_wing_api' do
        subject
      end
      sentry_tag_uuid = subject.sentry_tag_uuid
      expect(course.flags['update_logs'][1]['error_count']).to eq 2
      expect(course.flags['update_logs'][1]['sentry_tag_uuid']).to eq sentry_tag_uuid

      # Checking whether Sentry receives correct error and tags as arguments
      expect(Sentry).to have_received(:capture_exception)
        .exactly(2).times.with(Faraday::ConnectionFailed, anything)
      expect(Sentry).to have_received(:capture_exception)
        .exactly(2).times.with anything, hash_including(tags: { update_service_id: sentry_tag_uuid,
                                                                course: course.slug })
    end

    it 'tracks update errors properly in WikiApi' do
      allow(Sentry).to receive(:capture_exception)
      allow_any_instance_of(described_class).to receive(:update_article_status).and_return(nil)

      # Raising errors only in WikiApi
      allow_any_instance_of(MediawikiApi::Client).to receive(:send)
        .and_raise(MediawikiApi::ApiError)
      VCR.use_cassette 'course_update/wiki_api' do
        subject
      end
      sentry_tag_uuid = subject.sentry_tag_uuid
      expect(course.flags['update_logs'][1]['error_count']).to be_positive
      expect(course.flags['update_logs'][1]['sentry_tag_uuid']).to eq sentry_tag_uuid

      # Checking whether Sentry receives correct error and tags as arguments
      expect(Sentry).to have_received(:capture_exception)
        .at_least(2).times.with(MediawikiApi::ApiError, anything)
      expect(Sentry).to have_received(:capture_exception)
        .at_least(2).times.with anything, hash_including(tags: { update_service_id: sentry_tag_uuid,
                                                                course: course.slug })
    end

    context 'when a Programs & Events Dashboard course has a potentially long update time' do
      let(:course) do
        create(:course, start: 1.day.ago, end: 1.year.from_now,
                        flags: { longest_update: 1.hour.to_i })
      end

      before do
        allow(Features).to receive(:wiki_ed?).and_return(false)
      end

      it 'skips article status updates' do
        expect_any_instance_of(described_class).not_to receive(:update_article_status)
        subject
      end
    end
  end
end

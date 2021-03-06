class Submission < ActiveRecord::Base
  serialize :solution, JSON
  belongs_to :user
  belongs_to :user_exercise
  has_many :comments, ->{ order(created_at: :asc) }, dependent: :destroy

  # I don't really want the notifications method,
  # just the dependent destroy
  has_many :notifications, ->{ where(item_type: 'Submission') }, dependent: :destroy, foreign_key: 'item_id', class_name: 'Notification'

  has_many :submission_viewers, dependent: :destroy
  has_many :viewers, through: :submission_viewers

  has_many :muted_submissions, dependent: :destroy
  has_many :muted_by, through: :muted_submissions, source: :user

  has_many :likes, dependent: :destroy
  has_many :liked_by, through: :likes, source: :user

  validates_presence_of :user

  before_create do
    self.state          ||= "pending"
    self.nit_count      ||= 0
    self.version        ||= 0
    self.is_liked       ||= false
    self.key            ||= Exercism.uuid
    true
  end


  scope :done, ->{ where(state: 'done') }
  scope :pending, ->{ where(state: %w(needs_input pending)) }
  scope :hibernating, ->{ where(state: 'hibernating') }
  scope :needs_input, ->{ where(state: 'needs_input') }
  scope :aging, lambda {
    three_weeks_ago = Time.now - (60*60*24*7*3)
    cutoff = three_weeks_ago.strftime('%Y-%m-%d %H:%M:%S')
    pending.where('nit_count > 0').where('created_at < ?', cutoff)
  }
  scope :chronologically, -> { order('created_at ASC') }
  scope :reversed, -> { order(created_at: :desc) }
  scope :not_commented_on_by, ->(user) {
    joins("LEFT JOIN (SELECT submission_id FROM comments WHERE user_id=#{user.id}) AS already_commented ON submissions.id=already_commented.submission_id").
    where('already_commented.submission_id IS NULL')
  }
  scope :not_liked_by, ->(user) {
    joins("LEFT JOIN (SELECT submission_id FROM likes WHERE user_id=#{user.id}) AS already_liked ON submissions.id=already_liked.submission_id").
    where('already_liked.submission_id IS NULL')
  }
  scope :not_submitted_by, ->(user) { where.not(user: user) }

  scope :between, ->(upper_bound, lower_bound) {
    where('created_at < ? AND created_at > ?', upper_bound, lower_bound)
  }

  scope :older_than, ->(timestamp) {
    where('created_at < ?', timestamp)
  }

  scope :since, ->(timestamp) {
    where('created_at > ?', timestamp)
  }

  scope :for_language, ->(language) {
    where(language: language)
  }

  scope :excluding, ->(user) {
    where.not(user: user)
  }

  scope :recent, -> { where('submissions.created_at > ?', 7.days.ago) }

  def self.completed_for(problem)
    done.where(language: problem.track_id, slug: problem.slug)
  end

  def self.random_completed_for(problem)
    where(
      state: 'done',
      language: problem.track_id,
      slug: problem.slug
    ).order('RANDOM()').limit(1).first
  end

  def self.related(submission)
    order('created_at ASC').
      where(user_id: submission.user.id, language: submission.track_id, slug: submission.slug)
  end

  def self.on(problem)
    submission = new
    submission.on problem
    submission.save
    submission
  end

  def self.unmuted_for(user)
    joins("left join (select submission_id from muted_submissions ms where user_id=#{user.id}) as t ON t.submission_id=submissions.id").where('t.submission_id is null')
  end

  def name
    @name ||= slug.split('-').map(&:capitalize).join(' ')
  end

  def discussion_involves_user?
    nit_count < comments.count
  end

  def older_than?(time)
    self.created_at.utc < (Time.now.utc - time)
  end

  def track_id
    language
  end

  def problem
    @problem ||= Problem.new(track_id, slug)
  end

  def on(problem)
    self.language = problem.track_id

    self.slug = problem.slug
  end

  def supersede!
    self.state   = 'superseded'
    self.done_at = nil
    save
  end

  def submitted?
    true
  end

  def like!(user)
    self.is_liked = true
    self.liked_by << user unless liked_by.include?(user)
    mute(user)
    save
  end

  def unlike!(user)
    likes.where(user_id: user.id).destroy_all
    self.is_liked = liked_by.length > 0
    unmute(user)
    save
  end

  def liked?
    is_liked
  end

  def done?
    state == 'done'
  end

  def pending?
    state == 'pending'
  end

  def hibernating?
    state == 'hibernating'
  end

  def superseded?
    state == 'superseded'
  end

  def muted_by?(user)
    muted_submissions.where(user_id: user.id).exists?
  end

  def mute(user)
    muted_by << user
  end

  def mute!(user)
    mute(user)
    save
  end

  def unmute(user)
    muted_submissions.where(user_id: user.id).destroy_all
  end

  def unmute!(user)
    unmute(user)
    save
  end

  def unmute_all!
    muted_by.clear
    save
  end

  def viewed!(user)
    begin
      self.viewers << user unless viewers.include?(user)
    rescue => e
      # Temporarily output this to the logs
      puts "#{e.class}: #{e.message}"
    end
  end

  def view_count
    viewers.count
  end

  def exercise_completed?
    user_exercise.completed?
  end

  def exercise_hibernating?
    user_exercise.hibernating?
  end

  def prior
    @prior ||= related.where(version: version-1).first
  end

  def related
    @related ||= Submission.related(self)
  end

  private

  # Experiment: Cache the iteration number so that we can display it
  # on the dashboard without pulling down all the related versions
  # of the submission.
  # Preliminary testing in development suggests an 80% improvement.
  before_create do |document|
    self.version = Submission.related(self).count + 1
  end
end

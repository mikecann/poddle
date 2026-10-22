Feature: Your listening on the website
  As a Poddle listener
  I want to see my Up Next and shows on the website
  So I can check what's queued from any browser

  Scenario: Sign in, see your Up Next and shows, then sign out
    Given the listener follows "Morning Tones" with "Sunrise in A" and "Breakfast in C" in Up Next
    When they sign in on the website with test sign-in
    Then their Up Next on the website lists "Sunrise in A" then "Breakfast in C"
    And their shows on the website include "Morning Tones"
    When they sign out on the website
    Then the website asks them to sign in
    And their Up Next isn't on the page

  Scenario: Someone who isn't invited can't sign up
    When "stranger@poddle.test" tries test sign-in on the website
    Then the website says Poddle is invite-only
    And the website asks them to sign in

  Scenario: Delete your account
    Given the listener follows "Morning Tones"
    And they're signed in on the website
    When they delete their account on the website
    Then the website says their account is deleted
    And the listener has no account any more

  Scenario: A tab left open after the session ends asks you to sign in again
    Given the listener follows "Morning Tones"
    And they're signed in on the website
    When their session ends while the tab is still open
    Then the website asks them to sign in

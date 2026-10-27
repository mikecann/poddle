Feature: The home page
  As someone who's heard about Poddle
  I want the home page to show me what it is
  So I can get the app, or sign in if I already use it

  Scenario: A visitor finds the App Store badge and their way to sign in
    When a visitor opens the home page
    Then the home page shows Poddle with an App Store badge
    When they choose to sign in from the home page
    Then the website asks them to sign in

  Scenario: On a phone, sign in is in the menu
    When a visitor opens the home page on a phone
    And they open the menu and choose to sign in
    Then the website asks them to sign in

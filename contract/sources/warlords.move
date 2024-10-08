module warlords_addr::warlords {

    // ================================= Imports ================================= //
    use std::signer;
    use std::string::String;
    use std::vector;
    
    use aptos_framework::timestamp;
    use aptos_framework::randomness;
    use aptos_framework::event;

    // ================================= Errors ================================= //

    // Error indicating that Army size is not valid
    const ERR_INVALID_ARMY_SIZE: u64 = 1;
    // Error indicating that not enough turns are left for the action
    const ERR_NOT_ENOUGH_TURNS: u64 = 2;
    // Error indicating that the signer is not the king
    const ERR_NOT_KING: u64 = 3;
    // error code indicating that someone other than weatherman tried to change weather
    const ERR_NOT_WEATHERMAN: u64 = 4;
    // Error code indicating that the weatherman is trying to set a different weather
    const ERR_INVALID_WEATHER: u64 = 5;
    // Error code indicating that a player cannot attack themselves
    const ERR_CANNOT_ATTACK_SELF: u64 = 6;
    // Error code indicating that the last tick was too soon, min tick interval need to pass
    const ERR_TICK_TOO_SOON: u64 = 7;
    // Error code indicating player has already joined the game
    const ERR_ALREADY_JOINED: u64 = 8;
    // Error code indicating player has NOT joined the game
    const ERR_NOT_JOINED: u64 = 9;

    // ================================= Constants ============================== //
    const TICK_INTERVAL: u64 = 1; // 1 hour in seconds
    const MAX_DEFENSE_SIZE: u64 = 1600;
    const MAX_ATTACKER_SIZE: u64 = 2000;
    const INITIAL_TURN: u64 = 10;
    const WEATHER_BONUS_MULTIPLIER: u64 = 15; // 15% bonus
    const TURNS_NEEDED_TO_MOBILIZE: u64 = 1; 
    const TURNS_NEEDED_TO_ATTACK: u64 = 3;
    
    // possible weather conditions that can be set
    const CLEAR: u8 = 0;
    const CLOUDS: u8 = 1;
    const SNOW: u8 = 2;
    const RAIN: u8 = 3;
    const DRIZZLE: u8 = 4;
    const THUNDERSTORM: u8 = 5;

    // unit strength modifiers - Percentage modifiers (to avoid floating-point operations)
    const EXTREME_ADVANTAGE: u64 = 125; // 25% advantage
    const SIGNIFICANT_ADVANTAGE: u64 = 115; // 15% advantage
    const NO_EFFECT: u64 = 100;
    const SIGNIFICANT_DISADVANTAGE: u64 = 85; // 15% disadvantage
    const EXTREME_DISADVANTAGE: u64 = 75; // 25% disadvantage
    const SEVERE_DISADVANTAGE: u64 = 50; // 50% disadvantage

    // max random modifier
    const MAX_RANDOM_MODIFIER: u64 = 105; // 5% bonus


    // ================================= State/Structs/Enums ================================== //

    // Struct used as Global state for Castle Defense, 
    // Also used as Unique state for a player's Mobilized Army
    struct Army has store, drop, copy {
        archers: u64,
        cavalry: u64,
        infantry: u64,
    }

    // Global state for Castle's weather
    struct Weather has store, drop {
        value: u8,
        last_weather_change: u64
    }

    // Global state of the castles that everyone tries to capture
    struct Castle has store {
        king: address,
        defense: Army,
        weather: Weather,
        last_king_change: u64
    }

    // Global State holding game state 
    struct GameState has key {
        castle: Castle,
        weatherman: address,
        number_of_attacks: u64,
        game_turn: u64,
        last_tick_timestamp: u64,
        player_addresses: vector<address>, // all the players that joined the game
        highest_scorer: HighestScorer
    }

    // Store current leader address and points
    struct HighestScorer has store, drop {
        player_address: address,
        player_points: u64
    }

    // Unique state for a player's army and turn count
    struct PlayerState has key {
        general_name: String,
        army: Army,
        turns: u64,
        points : u64
    }

    // ================================= Events ================================== //

    #[event]
    struct AttackEvent has drop, store {
        attacker: address,
        defender: address,
        attacker_army: Army,
        defender_army: Army,
        winner: address,
    }

    #[event]
    struct TickEvent has drop, store {
        game_turn: u64,
        timestamp: u64,
    }

    // ================================= Module Init ================================== //

    fun init_module(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        
        move_to(sender, GameState {
            castle: Castle {
                king: sender_addr,
                defense: Army { archers: 500, cavalry: 500, infantry: 500 },
                weather: Weather { value: CLEAR, last_weather_change: timestamp::now_seconds() },
                last_king_change: timestamp::now_seconds()
            },
            weatherman: sender_addr,
            number_of_attacks: 0,
            game_turn: 0,
            last_tick_timestamp: 0,
            player_addresses: vector::empty<address>(),
            highest_scorer: HighestScorer { player_address: sender_addr, player_points: 0 }
        });
    }


    // ======================== Write functions ========================

    /*
    *  
    */
    public entry fun join_game(sender: &signer, general_name: String) acquires GameState {
        let sender_addr = signer::address_of(sender);

        assert!(!exists<PlayerState>(sender_addr), ERR_ALREADY_JOINED);

        move_to(sender, PlayerState {
            general_name: general_name,
            army: Army { archers: 500, cavalry: 500, infantry: 500 },
            turns: INITIAL_TURN,
            points: 0
        });

        // Add player address to the GameState
        let game_state = borrow_global_mut<GameState>(@warlords_addr);
        vector::push_back(&mut game_state.player_addresses, sender_addr);
    }

    public entry fun mobilize(
        sender: &signer, 
        archers: u64, 
        cavalry: u64, 
        infantry: u64
    ) acquires PlayerState {
        let sender_addr = signer::address_of(sender);
        assert!(exists<PlayerState>(sender_addr), ERR_NOT_JOINED);

        let player_state = borrow_global_mut<PlayerState>(sender_addr);
        assert!(player_state.turns >= TURNS_NEEDED_TO_MOBILIZE, ERR_NOT_ENOUGH_TURNS);

        let army = Army { archers, cavalry, infantry };
        assert!(calculate_base_strength(&army) <= MAX_ATTACKER_SIZE, ERR_INVALID_ARMY_SIZE);

        player_state.army = army;
        player_state.turns = player_state.turns - 1;
    }


    // Attack function to attack the castle based on randomness 
    // Since it uses the random api, it is marked as private
    // We prevent undergasing attack by making sure both winning and losing paths have same gas costs
    // in our case, we do the same calculations regardless of the random outcome
    #[randomness]
    entry fun attack_with_randomness(attacker: &signer) acquires PlayerState, GameState {
        let attacker_addr = signer::address_of(attacker);
        let attacker_state = borrow_global_mut<PlayerState>(attacker_addr);

        // players can only attack if they have enough turns 
        assert!(attacker_state.turns >= TURNS_NEEDED_TO_ATTACK, ERR_NOT_ENOUGH_TURNS);

        // players cannot attack themselves
        let game_state = borrow_global_mut<GameState>(@warlords_addr);
        assert!(game_state.castle.king != attacker_addr, ERR_CANNOT_ATTACK_SELF);

        let attacker_strength = calculate_effective_strength(&attacker_state.army, game_state.castle.weather.value);
        let defender_strength = calculate_effective_strength(&game_state.castle.defense, game_state.castle.weather.value);

        let random_bonus = randomness::u64_range(0, MAX_RANDOM_MODIFIER);
        attacker_strength = attacker_strength * random_bonus / 100;

        let winner: address;
        let default_defense_army: Army = Army { archers: 500, cavalry: 500, infantry: 500 };

        if (attacker_strength > defender_strength) {
            // Attacker wins
            game_state.castle.king = attacker_addr;
            game_state.castle.defense = default_defense_army;
            game_state.castle.last_king_change = timestamp::now_seconds();
            winner = attacker_addr;
            attacker_state.points = attacker_state.points + 1;
            if (attacker_state.points > game_state.highest_scorer.player_points) {
                game_state.highest_scorer = HighestScorer { player_address: attacker_addr, player_points: attacker_state.points };
            }
        } else {
            // Defender wins
            winner = game_state.castle.king;
        };

        attacker_state.turns = attacker_state.turns - TURNS_NEEDED_TO_ATTACK;
        game_state.number_of_attacks = game_state.number_of_attacks + 1;

        event::emit(AttackEvent {
            attacker: attacker_addr,
            defender: game_state.castle.king,
            attacker_army: attacker_state.army,
            defender_army: game_state.castle.defense,
            winner,
        });
    }


    // Attack function to attack the castle based on the current weather
    public entry fun attack(attacker: &signer) acquires PlayerState, GameState {

        let attacker_addr = signer::address_of(attacker);
        let attacker_state = borrow_global_mut<PlayerState>(attacker_addr);

        // players can only attack if they have enough turns 
        assert!(attacker_state.turns >= TURNS_NEEDED_TO_ATTACK, ERR_NOT_ENOUGH_TURNS);

        // players cannot attack themselves
        let game_state = borrow_global_mut<GameState>(@warlords_addr);
        assert!(game_state.castle.king != attacker_addr, ERR_CANNOT_ATTACK_SELF);

        let attacker_strength = calculate_effective_strength(&attacker_state.army, game_state.castle.weather.value);
        let defender_strength = calculate_effective_strength(&game_state.castle.defense, game_state.castle.weather.value);

        let winner: address;
        let default_defense_army: Army = Army { archers: 500, cavalry: 500, infantry: 500 };

        if (attacker_strength > defender_strength) {
            // Attacker wins
            game_state.castle.king = attacker_addr;
            game_state.castle.defense = default_defense_army;
            game_state.castle.last_king_change = timestamp::now_seconds();
            winner = attacker_addr;
            attacker_state.points = attacker_state.points + 1;
            if (attacker_state.points > game_state.highest_scorer.player_points) {
                game_state.highest_scorer = HighestScorer { player_address: attacker_addr, player_points: attacker_state.points };
            }
        } else {
            // Defender wins
            winner = game_state.castle.king;
        };

        attacker_state.turns = attacker_state.turns - TURNS_NEEDED_TO_ATTACK;
        game_state.number_of_attacks = game_state.number_of_attacks + 1;

        event::emit(AttackEvent {
            attacker: attacker_addr,
            defender: game_state.castle.king,
            attacker_army: attacker_state.army,
            defender_army: game_state.castle.defense,
            winner,
        });

    }

    public entry fun defend(sender: &signer, archers: u64, cavalry: u64, infantry: u64) acquires GameState {

        let sender_addr = signer::address_of(sender);
        let game_state_mut = borrow_global_mut<GameState>(@warlords_addr);

        // only the current castle king can change the castle defense 
        assert!(game_state_mut.castle.king == sender_addr, ERR_NOT_KING);

        let army = Army { archers, cavalry, infantry };
        // defending army has to follow game rules
        assert!(calculate_base_strength(&army) <= MAX_DEFENSE_SIZE, ERR_INVALID_ARMY_SIZE);

        game_state_mut.castle.defense = army;
    }

    public entry fun set_weather(sender: &signer, new_weather: u8) acquires GameState {

        // let sender_addr = signer::address_of(sender);
        let game_state_mut = borrow_global_mut<GameState>(@warlords_addr);

        // only the weatherman can set valid weather 
        // assert!(game_state_mut.weatherman == sender_addr, ERR_NOT_WEATHERMAN);
        assert!(new_weather <= THUNDERSTORM, ERR_INVALID_WEATHER);

        game_state_mut.castle.weather = Weather { 
            value: new_weather, 
            last_weather_change: timestamp::now_seconds() 
        };
    }

    public entry fun tick_tock() acquires GameState, PlayerState {

        let game_state_mut = borrow_global_mut<GameState>(@warlords_addr);
        let current_time = timestamp::now_seconds();
        let new_game_turn = game_state_mut.game_turn + 1;

        // make sure turns are not increased prematurely
        assert!(current_time >= game_state_mut.last_tick_timestamp + TICK_INTERVAL, ERR_TICK_TOO_SOON);


        game_state_mut.last_tick_timestamp = current_time;
        game_state_mut.game_turn = new_game_turn;
        
        // go through all the players, and increase their turns 

        let players = &game_state_mut.player_addresses;
        let len = vector::length<address>(players);

        for (i in 0..len) {
            let addr = *vector::borrow(players, i);
            let player_state = borrow_global_mut<PlayerState>(addr);
            player_state.turns = player_state.turns + 1;
        };

        event::emit(TickEvent {
            timestamp: current_time,
            game_turn: new_game_turn
        });
    }

    // ======================== Read Functions ========================

    #[view]
    public fun get_castle_info(): (address, Army, u8, u64, u64) acquires GameState {
        let game_state = borrow_global<GameState>(@warlords_addr);
        (
            game_state.castle.king,
            game_state.castle.defense,
            game_state.castle.weather.value,
            game_state.castle.weather.last_weather_change,
            game_state.castle.last_king_change
        )
    }

    #[view]
    public fun get_player_state(player: address): (String, Army, u64, u64) acquires PlayerState {
        assert!(exists<PlayerState>(player), ERR_NOT_JOINED);
        let player_state = borrow_global<PlayerState>(player);
        (player_state.general_name, player_state.army, player_state.turns, player_state.points)
    }

    #[view]
    public fun get_last_tick_timestamp(): u64 acquires GameState {
        let game_state = borrow_global<GameState>(@warlords_addr);
        game_state.last_tick_timestamp
    }

    #[view]
    public fun get_last_king_timestamp(): u64 acquires GameState {
        let game_state = borrow_global<GameState>(@warlords_addr);
        game_state.castle.last_king_change
    }

    #[view]
    public fun get_top_points(): u64 acquires GameState {
        let game_state = borrow_global<GameState>(@warlords_addr);
        game_state.highest_scorer.player_points
    }


    // ======================== Helper functions ========================

    fun calculate_random_bonus(army: &Army, random_bonus: u8): u64 {
        let base = calculate_base_strength(army);
        let effective_random: u64 = random_bonus as u64;
        base * effective_random / 100
    }

    fun calculate_base_strength(army: &Army): u64 {
        army.archers + army.cavalry + army.infantry
    }

    fun calculate_effective_strength_random(army: &Army, weather: u8): u64 {
        let archers_strength = army.archers * get_archer_modifier(weather) / 100;
        let cavalry_strength = army.cavalry * get_cavalry_modifier(weather) / 100;
        let infantry_strength = army.infantry * get_infantry_modifier(weather) / 100;
        archers_strength + cavalry_strength + infantry_strength
    }

    fun calculate_effective_strength(army: &Army, weather: u8): u64 {
        let archers_strength = army.archers * get_archer_modifier(weather) / 100;
        let cavalry_strength = army.cavalry * get_cavalry_modifier(weather) / 100;
        let infantry_strength = army.infantry * get_infantry_modifier(weather) / 100;
        archers_strength + cavalry_strength + infantry_strength
    }

    fun get_archer_modifier(weather: u8): u64 {
        if (weather == CLEAR) {
            EXTREME_ADVANTAGE
        } else if (weather == CLOUDS) {
            SIGNIFICANT_ADVANTAGE
        } else if (weather == SNOW) {
            NO_EFFECT
        } else if (weather == RAIN || weather == DRIZZLE) {
            SIGNIFICANT_DISADVANTAGE
        } else if (weather == THUNDERSTORM) {
            EXTREME_DISADVANTAGE
        } else {
            NO_EFFECT // Default case, should never happen
        }
    }

    fun get_cavalry_modifier(weather: u8): u64 {
        if (weather == CLEAR) {
            SIGNIFICANT_ADVANTAGE
        } else if (weather == CLOUDS) {
            EXTREME_ADVANTAGE
        } else if (weather == SNOW || weather == DRIZZLE) {
            SIGNIFICANT_DISADVANTAGE
        } else if (weather == RAIN) {
            EXTREME_DISADVANTAGE
        } else if (weather == THUNDERSTORM) {
            SEVERE_DISADVANTAGE
        } else {
            NO_EFFECT // Default case, should never happen
        }
    }

    fun get_infantry_modifier(weather: u8): u64 {
        if (weather == CLEAR || weather == CLOUDS) {
            NO_EFFECT
        } else if (weather == DRIZZLE || weather == SNOW) {
            SIGNIFICANT_ADVANTAGE
        } else if (weather == RAIN || weather == THUNDERSTORM) {
            EXTREME_ADVANTAGE
        } else {
            NO_EFFECT // Default case, should never happen
        }
    }


    public fun get_army_strength(army: &Army): u64 {
        army.archers + army.cavalry + army.infantry
    }

    // ======================== Test Helper functions ========================

    #[test_only]
    public fun init_module_for_test(sender: &signer)  {
        init_module(sender);
    }

    #[test_only]
    public fun get_army_details(army: &Army): (u64, u64, u64) {
        (army.archers, army.cavalry, army.infantry)
    }

    #[test_only]
    #[lint::allow_unsafe_randomness]
    public fun attack_with_randomness_for_test(attacker: &signer) acquires PlayerState, GameState {
        attack_with_randomness(attacker);
    }

}
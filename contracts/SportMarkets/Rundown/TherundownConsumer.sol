// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// internal
import "../../utils/proxy/solidity-0.8.0/ProxyOwned.sol";
import "../../utils/proxy/solidity-0.8.0/ProxyPausable.sol";
import "./GamesQueue.sol";

// interface
import "../../interfaces/ISportPositionalMarketManager.sol";
import "../../interfaces/ITherundownConsumerVerifier.sol";
import "../../interfaces/IGamesOddsObtainer.sol";
import "../../interfaces/ISportPositionalMarket.sol";
import "../../interfaces/IGamesPlayerProps.sol";

/// @title Consumer contract which stores all data from CL data feed (Link to docs: https://market.link/nodes/TheRundown/integrations), also creates all sports markets based on that data
/// @author gruja
contract TherundownConsumer is Initializable, ProxyOwned, ProxyPausable {
    /* ========== CONSTANTS =========== */

    uint public constant CANCELLED = 0;
    uint public constant HOME_WIN = 1;
    uint public constant AWAY_WIN = 2;
    uint public constant RESULT_DRAW = 3;
    uint public constant MIN_TAG_NUMBER = 9000;
    uint public constant STATUS_RETIRED = 201;

    /* ========== CONSUMER STATE VARIABLES ========== */

    struct GameCreate {
        bytes32 gameId;
        uint256 startTime;
        int24 homeOdds;
        int24 awayOdds;
        int24 drawOdds;
        string homeTeam;
        string awayTeam;
    }

    struct GameResolve {
        bytes32 gameId;
        uint8 homeScore;
        uint8 awayScore;
        uint8 statusId;
        uint40 lastUpdated;
    }

    struct GameOdds {
        bytes32 gameId;
        int24 homeOdds;
        int24 awayOdds;
        int24 drawOdds;
    }

    /* ========== STATE VARIABLES ========== */

    // global params
    address public wrapperAddress;
    mapping(address => bool) public whitelistedAddresses;

    // Maps <RequestId, Result>
    mapping(bytes32 => bytes[]) private requestIdGamesCreated; // deprecated see Wrapper
    mapping(bytes32 => bytes[]) private requestIdGamesResolved; // deprecated see Wrapper
    mapping(bytes32 => bytes[]) private requestIdGamesOdds; // deprecated see Wrapper

    // Maps <GameId, Game>
    mapping(bytes32 => GameCreate) public gameCreated;
    mapping(bytes32 => GameResolve) public gameResolved;
    mapping(bytes32 => GameOdds) private gameOdds; // deprecated see GamesOddsObtainer
    mapping(bytes32 => uint) public sportsIdPerGame;
    mapping(bytes32 => bool) public gameFulfilledCreated;
    mapping(bytes32 => bool) public gameFulfilledResolved;

    // sports props
    mapping(uint => bool) public supportedSport;
    mapping(uint => bool) public twoPositionSport;
    mapping(uint => bool) public supportResolveGameStatuses;
    mapping(uint => bool) public cancelGameStatuses;

    // market props
    ISportPositionalMarketManager public sportsManager;
    mapping(bytes32 => address) public marketPerGameId;
    mapping(address => bytes32) public gameIdPerMarket;
    mapping(address => bool) public marketResolved;
    mapping(address => bool) public marketCanceled;

    // game
    GamesQueue public queues;
    mapping(bytes32 => uint) private oddsLastPulledForGame; // deprecated see GamesOddsObtainer
    mapping(uint => bytes32[]) private gamesPerDate; // deprecated use gamesPerDatePerSport
    mapping(uint => mapping(uint => bool)) public isSportOnADate;
    mapping(address => bool) private invalidOdds; // deprecated see GamesOddsObtainer
    mapping(address => bool) public marketCreated;
    mapping(uint => mapping(uint => bytes32[])) public gamesPerDatePerSport;
    mapping(address => bool) public isPausedByCanceledStatus;
    mapping(address => bool) private canMarketBeUpdated; // deprecated
    mapping(bytes32 => uint) public gameOnADate;

    ITherundownConsumerVerifier public verifier;
    mapping(bytes32 => GameOdds) private backupOdds; // deprecated see GamesOddsObtainer
    IGamesOddsObtainer public oddsObtainer;
    uint public maxNumberOfMarketsToResolve;
    IGamesPlayerProps public playerProps;
    mapping(uint => bool) public ignoreChildCancellationPerSportIfDraw;
    uint public maxNumberOfMarketsToCreate;
    mapping(string => address) public marketForTeamName;

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _owner,
        uint[] memory _supportedSportIds,
        address _sportsManager,
        uint[] memory _twoPositionSports,
        GamesQueue _queues,
        uint[] memory _resolvedStatuses,
        uint[] memory _cancelGameStatuses
    ) external initializer {
        setOwner(_owner);

        for (uint i; i < _supportedSportIds.length; i++) {
            supportedSport[_supportedSportIds[i]] = true;
        }
        for (uint i; i < _twoPositionSports.length; i++) {
            twoPositionSport[_twoPositionSports[i]] = true;
        }
        for (uint i; i < _resolvedStatuses.length; i++) {
            supportResolveGameStatuses[_resolvedStatuses[i]] = true;
        }
        for (uint i; i < _cancelGameStatuses.length; i++) {
            cancelGameStatuses[_cancelGameStatuses[i]] = true;
        }

        sportsManager = ISportPositionalMarketManager(_sportsManager);
        queues = _queues;
        whitelistedAddresses[_owner] = true;
    }

    /* ========== CONSUMER FULFILL FUNCTIONS ========== */

    /// @notice fulfill all data necessary to create sport markets
    /// @param _requestId unique request id form CL
    /// @param _games array of a games that needed to be stored and transfered to markets
    /// @param _sportId sports id which is provided from CL (Example: NBA = 4)
    /// @param _date date on which game/games are played
    function fulfillGamesCreated(
        bytes32 _requestId,
        bytes[] memory _games,
        uint _sportId,
        uint _date
    ) external onlyWrapper {
        uint doubleChanceMultiplier = sportsManager.doesSportSupportDoubleChance(_sportId) ? 3 : 0;
        uint numOfMarkets = twoPositionSport[_sportId] ? _games.length : _games.length * (1 + doubleChanceMultiplier);

        if (_games.length > 0) {
            isSportOnADate[_date][_sportId] = true;
        }

        for (uint i = 0; i < _games.length; i++) {
            GameCreate memory gameForProcessing = abi.decode(_games[i], (GameCreate));
            // new game
            if (
                !gameFulfilledCreated[gameForProcessing.gameId] &&
                !verifier.isInvalidNames(gameForProcessing.homeTeam, gameForProcessing.awayTeam) &&
                gameForProcessing.startTime > block.timestamp
            ) {
                _updateGameOnADate(gameForProcessing.gameId, _date, _sportId);
                _createGameFulfill(_requestId, gameForProcessing, _sportId, numOfMarkets);
            }
            // old game UFC checking fighters
            else if (gameFulfilledCreated[gameForProcessing.gameId]) {
                GameCreate memory currentGameValues = getGameCreatedById(gameForProcessing.gameId);

                // if name (away or home) not the same
                if (
                    (!verifier.areTeamsEqual(gameForProcessing.homeTeam, currentGameValues.homeTeam) ||
                        !verifier.areTeamsEqual(gameForProcessing.awayTeam, currentGameValues.awayTeam))
                ) {
                    // double-check if market exists -> cancel market -> create new for queue
                    if (marketCreated[marketPerGameId[gameForProcessing.gameId]]) {
                        if (_sportId == 7) {
                            _cancelMarket(gameForProcessing.gameId, false);
                            _updateGameOnADate(gameForProcessing.gameId, _date, _sportId);
                            _createGameFulfill(_requestId, gameForProcessing, _sportId, numOfMarkets);
                        } else {
                            _pauseOrUnpauseMarket(marketPerGameId[gameForProcessing.gameId], true);
                            oddsObtainer.pauseUnpauseChildMarkets(marketPerGameId[gameForProcessing.gameId], true);
                            _pauseOrUnpausePlayerProps(marketPerGameId[gameForProcessing.gameId], true, false, false);
                        }
                    }
                    // checking time
                } else if (gameForProcessing.startTime != currentGameValues.startTime) {
                    _updateGameOnADate(gameForProcessing.gameId, _date, _sportId);
                    // if NEW start time is in future
                    if (gameForProcessing.startTime > block.timestamp) {
                        // this checks is for new markets
                        sportsManager.updateDatesForMarket(
                            marketPerGameId[gameForProcessing.gameId],
                            gameForProcessing.startTime
                        );
                        gameCreated[gameForProcessing.gameId] = gameForProcessing;
                    } else {
                        // double-check if market existst
                        if (
                            marketCreated[marketPerGameId[gameForProcessing.gameId]] &&
                            currentGameValues.startTime > block.timestamp
                        ) {
                            _pauseOrUnpauseMarket(marketPerGameId[gameForProcessing.gameId], true);
                            oddsObtainer.pauseUnpauseChildMarkets(marketPerGameId[gameForProcessing.gameId], true);
                            _pauseOrUnpausePlayerProps(marketPerGameId[gameForProcessing.gameId], true, false, false);
                            emit GameTimeMovedAhead(
                                marketPerGameId[gameForProcessing.gameId],
                                gameForProcessing.gameId,
                                currentGameValues.startTime,
                                gameForProcessing.startTime
                            );
                        }
                    }
                }
            }
        }
    }

    /// @notice fulfill all data necessary to resolve sport markets
    /// @param _requestId unique request id form CL
    /// @param _games array of a games that needed to be resolved
    /// @param _sportId sports id which is provided from CL (Example: NBA = 4)
    function fulfillGamesResolved(
        bytes32 _requestId,
        bytes[] memory _games,
        uint _sportId
    ) external onlyWrapper {
        uint numberOfMarketsToResolve = _games.length;
        for (uint i = 0; i < _games.length; i++) {
            GameResolve memory game = abi.decode(_games[i], (GameResolve));
            address _main = marketPerGameId[game.gameId];
            numberOfMarketsToResolve = numberOfMarketsToResolve + oddsObtainer.numberOfChildMarkets(_main);
        }
        for (uint i = 0; i < _games.length; i++) {
            GameResolve memory game = abi.decode(_games[i], (GameResolve));
            // if game is not resolved already and there is market for that game
            if (!gameFulfilledResolved[game.gameId] && marketPerGameId[game.gameId] != address(0)) {
                _resolveGameFulfill(_requestId, game, _sportId, numberOfMarketsToResolve);
            }
        }
    }

    /// @notice fulfill all data necessary to populate odds of a game
    /// @param _requestId unique request id form CL
    /// @param _games array of a games that needed to update the odds
    function fulfillGamesOdds(bytes32 _requestId, bytes[] memory _games) external onlyWrapper {
        for (uint i = 0; i < _games.length; i++) {
            IGamesOddsObtainer.GameOdds memory game = abi.decode(_games[i], (IGamesOddsObtainer.GameOdds));
            // game needs to be fulfilled and market needed to be created
            if (gameFulfilledCreated[game.gameId] && marketPerGameId[game.gameId] != address(0)) {
                oddsObtainer.obtainOdds(
                    _requestId,
                    game,
                    sportsIdPerGame[game.gameId],
                    marketPerGameId[game.gameId],
                    twoPositionSport[sportsIdPerGame[game.gameId]],
                    false
                );
            }
        }
    }

    /// @notice creates market for a given game id
    /// @param _gameId game id
    function createMarketForGame(bytes32 _gameId) public {
        require(
            marketPerGameId[_gameId] == address(0) ||
                (marketCanceled[marketPerGameId[_gameId]] && marketPerGameId[_gameId] != address(0)),
            "ID1"
        );
        require(gameFulfilledCreated[_gameId], "ID2");
        require(queues.gamesCreateQueue(queues.firstCreated()) == _gameId, "ID3");
        _createMarket(_gameId, true);
    }

    /// @notice creates markets for a given game ids
    /// @param _gameIds game ids as array
    function createAllMarketsForGames(bytes32[] memory _gameIds) external {
        for (uint i; i < _gameIds.length; i++) {
            createMarketForGame(_gameIds[i]);
        }
    }

    /// @notice resolve market for a given game id
    /// @param _gameId game id
    function resolveMarketForGame(bytes32 _gameId) public {
        require(!isGameResolvedOrCanceled(_gameId), "ID4");
        require(gameFulfilledResolved[_gameId], "ID5");
        _resolveMarket(_gameId, false);
    }

    /// @notice resolve all markets for a given game ids
    /// @param _gameIds game ids as array
    function resolveAllMarketsForGames(bytes32[] memory _gameIds) external {
        for (uint i; i < _gameIds.length; i++) {
            resolveMarketForGame(_gameIds[i]);
        }
    }

    /// @notice resolve market for a given market address
    /// @param _market market address
    /// @param _outcome outcome of a game (1: home win, 2: away win, 3: draw, 0: cancel market)
    /// @param _homeScore score of home team
    /// @param _awayScore score of away team
    function resolveMarketManually(
        address _market,
        uint _outcome,
        uint8 _homeScore,
        uint8 _awayScore,
        bool _useBackupOdds
    ) external isAddressWhitelisted canGameBeResolved(gameIdPerMarket[_market], _outcome, _homeScore, _awayScore) {
        _resolveMarketManually(_market, _outcome, _homeScore, _awayScore, _useBackupOdds);
    }

    /// @notice pause/unpause market for a given market address
    /// @param _market market address
    /// @param _pause pause = true, unpause = false
    function pauseOrUnpauseMarketManually(address _market, bool _pause) external isAddressWhitelisted {
        require(gameIdPerMarket[_market] != 0 && gameFulfilledCreated[gameIdPerMarket[_market]], "ID20");
        _pauseOrUnpauseMarketManually(_market, _pause);
    }

    /// @notice reopen game for processing the creation again
    /// @param gameId gameId
    function reopenGameForCreationProcessing(bytes32 gameId) external isAddressWhitelisted {
        require(gameFulfilledCreated[gameId], "ID22");
        gameFulfilledCreated[gameId] = false;
        gameFulfilledResolved[gameId] = false;
    }

    /// @notice setting isPausedByCanceledStatus from obtainer see @GamesOddsObtainer
    /// @param _market market address
    /// @param _flag flag true/false
    function setPausedByCanceledStatus(address _market, bool _flag) external canExecute {
        isPausedByCanceledStatus[_market] = _flag;
    }

    /// @notice pause market from obtainer see @GamesOddsObtainer
    /// @param _market market address
    /// @param _pause flag true/false
    function pauseOrUnpauseMarket(address _market, bool _pause) external canExecute {
        _pauseOrUnpauseMarket(_market, _pause);
    }

    /// @notice pause market from obtainer see @GamesOddsObtainer
    /// @param _main market address
    /// @param _pause flag true/false
    /// @param _invalidOdds flag true/false for invalid odds
    /// @param _circuitBreaker flag true/false for circuit breaker
    function pauseOrUnpauseMarketForPlayerProps(
        address _main,
        bool _pause,
        bool _invalidOdds,
        bool _circuitBreaker
    ) external canExecute {
        _pauseOrUnpausePlayerProps(_main, _pause, _invalidOdds, _circuitBreaker);
    }

    /// @notice setting gameid per market
    /// @param _gameId game id
    /// @param _child child market address
    function setGameIdPerChildMarket(bytes32 _gameId, address _child) external canExecute {
        gameIdPerMarket[_child] = _gameId;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice view function which returns game created object based on id of a game
    /// @param _gameId game id
    /// @return GameCreate game create object
    function getGameCreatedById(bytes32 _gameId) public view returns (GameCreate memory) {
        return gameCreated[_gameId];
    }

    /// @notice view function which returns game startTime
    /// @param _gameId game id
    function getGameStartTime(bytes32 _gameId) external view returns (uint256) {
        return gameCreated[_gameId].startTime;
    }

    /// @notice view function which returns lastUpdated from GameResolved struct
    /// @param _gameId game id
    function getLastUpdatedFromGameResolve(bytes32 _gameId) external view returns (uint40) {
        return gameResolved[_gameId].lastUpdated;
    }

    /// @notice view function which returns games on certan date and sportid
    /// @param _sportId date
    /// @param _date date
    /// @return bytes32[] list of games
    function getGamesPerDatePerSport(uint _sportId, uint _date) external view returns (bytes32[] memory) {
        return gamesPerDatePerSport[_sportId][_date];
    }

    /// @notice view function which returns props (sportid and game date)
    /// @param _market market address
    /// @return _sportId sport ids
    /// @return _gameDate game date on which game is playing
    function getGamePropsForOdds(address _market)
        external
        view
        returns (
            uint _sportId,
            uint _gameDate,
            bytes32 _id
        )
    {
        return (sportsIdPerGame[gameIdPerMarket[_market]], gameOnADate[gameIdPerMarket[_market]], gameIdPerMarket[_market]);
    }

    /// @notice view function which returns if game is resolved or canceled and ready for market to be resolved or canceled
    /// @param _gameId game id for which game is looking
    /// @return bool is it ready for resolve or cancel true/false
    function isGameResolvedOrCanceled(bytes32 _gameId) public view returns (bool) {
        return marketResolved[marketPerGameId[_gameId]] || marketCanceled[marketPerGameId[_gameId]];
    }

    /// @notice view function which returns if sport is two positional (no draw, example: NBA)
    /// @param _sportsId sport id for which is looking
    /// @return bool is sport two positional true/false
    function isSportTwoPositionsSport(uint _sportsId) public view returns (bool) {
        return twoPositionSport[_sportsId];
    }

    /// @notice view function which returns if market is child or not
    /// @param _market address of the checked market
    /// @return bool if the _market is child or not (true/false)
    function isChildMarket(address _market) public view returns (bool) {
        return oddsObtainer.childMarketMainMarket(_market) != address(0);
    }

    /// @notice view function which returns normalized odds up to 100 (Example: 50-40-10)
    /// @param _market market
    /// @return uint[] odds array normalized
    function getNormalizedOddsForMarket(address _market) external view returns (uint[] memory) {
        return marketCreated[_market] ? _getNormalizedOdds(gameIdPerMarket[_market]) : _getNormalizedChildOdds(_market);
    }

    /* ========== INTERNALS ========== */

    function _createGameFulfill(
        bytes32 requestId,
        GameCreate memory _game,
        uint _sportId,
        uint _numberOfGames
    ) internal {
        bool automaticCreation = _numberOfGames < maxNumberOfMarketsToCreate;
        gameCreated[_game.gameId] = _game;
        sportsIdPerGame[_game.gameId] = _sportId;
        if (!automaticCreation) {
            queues.enqueueGamesCreated(_game.gameId, _game.startTime, _sportId);
        }
        gameFulfilledCreated[_game.gameId] = true;
        oddsObtainer.setFirstOdds(_game.gameId, _game.homeOdds, _game.awayOdds, _game.drawOdds);

        emit GameCreated(requestId, _sportId, _game.gameId, _game, queues.lastCreated(), _getNormalizedOdds(_game.gameId));

        if (automaticCreation) {
            _createMarket(_game.gameId, false);
        }
    }

    function _resolveGameFulfill(
        bytes32 requestId,
        GameResolve memory _game,
        uint _sportId,
        uint _numberOfMarketsToResolve
    ) internal {
        GameCreate memory singleGameCreated = getGameCreatedById(_game.gameId);

        // if status is resolved OR (status is canceled AND start time has passed fulfill game to be resolved)
        if (
            _isGameStatusResolved(_game) ||
            (cancelGameStatuses[_game.statusId] && singleGameCreated.startTime < block.timestamp)
        ) {
            gameResolved[_game.gameId] = _game;
            gameFulfilledResolved[_game.gameId] = true;

            emit GameResolved(requestId, _sportId, _game.gameId, _game, queues.lastResolved());

            if (_numberOfMarketsToResolve >= maxNumberOfMarketsToResolve) {
                queues.enqueueGamesResolved(_game.gameId);
            } else {
                _resolveMarket(_game.gameId, true);
            }
        }
        // if status is canceled AND start time has not passed only pause market
        else if (cancelGameStatuses[_game.statusId] && singleGameCreated.startTime >= block.timestamp) {
            isPausedByCanceledStatus[marketPerGameId[_game.gameId]] = true;
            _pauseOrUnpauseMarket(marketPerGameId[_game.gameId], true);
            oddsObtainer.pauseUnpauseChildMarkets(marketPerGameId[_game.gameId], true);
            _pauseOrUnpausePlayerProps(marketPerGameId[_game.gameId], true, false, false);
        }
    }

    function _createMarket(bytes32 _gameId, bool _removeFromQueue) internal {
        GameCreate memory game = getGameCreatedById(_gameId);
        // only markets in a future, if not dequeue that creation
        if (game.startTime > block.timestamp) {
            uint[] memory tags = _calculateTags(sportsIdPerGame[_gameId]);

            // create
            ISportPositionalMarket market = sportsManager.createMarket(
                _gameId,
                string(abi.encodePacked(game.homeTeam, " vs ", game.awayTeam)), // gameLabel
                game.startTime, //maturity
                0, //initialMint
                twoPositionSport[sportsIdPerGame[_gameId]] ? 2 : 3,
                tags, //tags
                false,
                address(0)
            );

            marketPerGameId[game.gameId] = address(market);
            gameIdPerMarket[address(market)] = game.gameId;
            marketCreated[address(market)] = true;

            oddsObtainer.setFirstNormalizedOdds(game.gameId, address(market));
            marketForTeamName[game.homeTeam] = address(market);
            marketForTeamName[game.awayTeam] = address(market);

            if (_removeFromQueue) {
                queues.dequeueGamesCreated();
            }
            emit CreateSportsMarket(address(market), game.gameId, game, tags, _getNormalizedOdds(game.gameId));
        } else {
            if (_removeFromQueue) {
                queues.dequeueGamesCreated();
            }
        }
    }

    function _resolveMarket(bytes32 _gameId, bool _resolveMarketWithoutQueue) internal {
        GameResolve memory game = gameResolved[_gameId];
        GameCreate memory singleGameCreated = getGameCreatedById(_gameId);

        if (_isGameStatusResolved(game)) {
            if (oddsObtainer.invalidOdds(marketPerGameId[game.gameId])) {
                _pauseOrUnpauseMarket(marketPerGameId[game.gameId], false);
                oddsObtainer.pauseUnpauseChildMarkets(marketPerGameId[game.gameId], false);
                _pauseOrUnpausePlayerProps(marketPerGameId[game.gameId], false, false, false);
            }

            (uint _outcome, uint8 _homeScore, uint8 _awayScore) = _calculateOutcome(game);

            // if result is draw and game is two positional
            if (_outcome == RESULT_DRAW && twoPositionSport[sportsIdPerGame[game.gameId]]) {
                if (ignoreChildCancellationPerSportIfDraw[sportsIdPerGame[game.gameId]]) {
                    _cancelMainResolveChild(
                        marketPerGameId[game.gameId],
                        _outcome,
                        _homeScore,
                        _awayScore,
                        !_resolveMarketWithoutQueue
                    );
                } else {
                    _cancelMarket(game.gameId, !_resolveMarketWithoutQueue);
                }
            } else {
                // if market is paused only remove from queue
                if (!sportsManager.isMarketPaused(marketPerGameId[game.gameId])) {
                    _setMarketCancelOrResolved(
                        marketPerGameId[game.gameId],
                        _outcome,
                        _homeScore,
                        _awayScore,
                        game.statusId
                    );
                    if (!_resolveMarketWithoutQueue) {
                        _cleanStorageQueue();
                    }

                    emit ResolveSportsMarket(marketPerGameId[game.gameId], game.gameId, _outcome);
                } else {
                    if (!_resolveMarketWithoutQueue) {
                        _cleanStorageQueue();
                    }
                }
            }
            // if status is canceled and start time of a game passed cancel market
        } else if (cancelGameStatuses[game.statusId] && singleGameCreated.startTime < block.timestamp) {
            _cancelMarket(game.gameId, !_resolveMarketWithoutQueue);
        }
    }

    function _resolveMarketManually(
        address _market,
        uint _outcome,
        uint8 _homeScore,
        uint8 _awayScore,
        bool _useBackupOdds
    ) internal {
        if (_useBackupOdds) {
            require(_outcome == CANCELLED, "ID17");
            require(
                oddsObtainer.areOddsValid(
                    gameIdPerMarket[_market],
                    _useBackupOdds,
                    twoPositionSport[sportsIdPerGame[gameIdPerMarket[_market]]]
                )
            );
            oddsObtainer.setBackupOddsAsMainOddsForGame(gameIdPerMarket[_market]);
        }

        _pauseOrUnpauseMarket(_market, false);
        oddsObtainer.pauseUnpauseChildMarkets(_market, false);
        _pauseOrUnpausePlayerProps(_market, false, false, false);
        _setMarketCancelOrResolved(
            _market,
            _outcome,
            _homeScore,
            _awayScore,
            twoPositionSport[sportsIdPerGame[gameIdPerMarket[_market]]] ? 8 : 11
        );
        gameResolved[gameIdPerMarket[_market]] = GameResolve(
            gameIdPerMarket[_market],
            _homeScore,
            _awayScore,
            twoPositionSport[sportsIdPerGame[gameIdPerMarket[_market]]] ? 8 : 11,
            0
        );

        emit GameResolved(
            gameIdPerMarket[_market], // no req. from CL (manual resolve) so just put gameID
            sportsIdPerGame[gameIdPerMarket[_market]],
            gameIdPerMarket[_market],
            gameResolved[gameIdPerMarket[_market]],
            0
        );

        if (_outcome == CANCELLED) {
            emit CancelSportsMarket(_market, gameIdPerMarket[_market]);
        } else {
            emit ResolveSportsMarket(_market, gameIdPerMarket[_market], _outcome);
        }
    }

    function _pauseOrUnpauseMarketManually(address _market, bool _pause) internal {
        _pauseOrUnpauseMarket(_market, _pause);
        oddsObtainer.pauseUnpauseCurrentActiveChildMarket(gameIdPerMarket[_market], _market, _pause);
    }

    function _pauseOrUnpausePlayerProps(
        address _market,
        bool _pause,
        bool _invalidOdds,
        bool _circuitBreaker
    ) internal {
        playerProps.pauseAllPlayerPropsMarketForMain(_market, _pause, _invalidOdds, _circuitBreaker);
    }

    function _pauseOrUnpauseMarket(address _market, bool _pause) internal {
        if (sportsManager.isMarketPaused(_market) != _pause) {
            sportsManager.setMarketPaused(_market, _pause);
            emit PauseSportsMarket(_market, _pause);
        }
    }

    function _cancelMarket(bytes32 _gameId, bool cleanStorage) internal {
        _setMarketCancelOrResolved(marketPerGameId[_gameId], CANCELLED, 0, 0, 0);
        if (cleanStorage) {
            _cleanStorageQueue();
        }

        emit CancelSportsMarket(marketPerGameId[_gameId], _gameId);
    }

    function _setMarketCancelOrResolved(
        address _market,
        uint _outcome,
        uint8 _homeScore,
        uint8 _awayScore,
        uint8 _status
    ) internal {
        sportsManager.resolveMarket(_market, _outcome);
        if (_status == STATUS_RETIRED) {
            oddsObtainer.resolveChildMarkets(_market, 0, 0, 0);
        } else {
            oddsObtainer.resolveChildMarkets(_market, _outcome, _homeScore, _awayScore);
            if (_outcome == CANCELLED) {
                playerProps.cancelPlayerPropsMarketForMain(_market);
            }
        }
        marketCanceled[_market] = _outcome == CANCELLED;
        marketResolved[_market] = _outcome != CANCELLED;
    }

    function _cancelMainResolveChild(
        address _market,
        uint _outcome,
        uint8 _homeScore,
        uint8 _awayScore,
        bool _cleanStorage
    ) internal {
        sportsManager.resolveMarket(_market, 0); // cancel main
        oddsObtainer.resolveChildMarkets(_market, _outcome, _homeScore, _awayScore);
        marketCanceled[_market] = false;
        marketResolved[_market] = true; // must be true because of player props resolve
        if (_cleanStorage) {
            _cleanStorageQueue();
        }
        emit CancelSportsMarket(_market, gameIdPerMarket[_market]);
    }

    function _cleanStorageQueue() internal {
        queues.dequeueGamesResolved();
    }

    function _calculateTags(uint _sportsId) internal pure returns (uint[] memory) {
        uint[] memory result = new uint[](1);
        result[0] = MIN_TAG_NUMBER + _sportsId;
        return result;
    }

    function _isGameStatusResolved(GameResolve memory _game) internal view returns (bool) {
        return supportResolveGameStatuses[_game.statusId];
    }

    function _calculateOutcome(GameResolve memory _game)
        internal
        pure
        returns (
            uint,
            uint8,
            uint8
        )
    {
        if (_game.homeScore == _game.awayScore) {
            return (RESULT_DRAW, _game.homeScore, _game.awayScore);
        }
        return
            _game.homeScore > _game.awayScore
                ? (HOME_WIN, _game.homeScore, _game.awayScore)
                : (AWAY_WIN, _game.homeScore, _game.awayScore);
    }

    function _updateGameOnADate(
        bytes32 _gameId,
        uint _date,
        uint _sportId
    ) internal {
        if (gameOnADate[_gameId] != _date) {
            gamesPerDatePerSport[_sportId][_date].push(_gameId);
            gameOnADate[_gameId] = _date;
        }
    }

    function _getNormalizedOdds(bytes32 _gameId) internal view returns (uint[] memory) {
        return oddsObtainer.getNormalizedOdds(_gameId);
    }

    function _getNormalizedChildOdds(address _market) internal view returns (uint[] memory) {
        return
            oddsObtainer.childMarketCreated(_market)
                ? oddsObtainer.getNormalizedOddsForMarket(_market)
                : playerProps.getNormalizedOddsForMarket(_market);
    }

    /* ========== CONTRACT MANAGEMENT ========== */

    /// @notice sets if sport is suported or not (delete from supported sport)
    /// @param _sportId sport id which needs to be supported or not
    /// @param _isSupported true/false (supported or not)
    function setSupportedSport(uint _sportId, bool _isSupported) external onlyOwner {
        require(supportedSport[_sportId] != _isSupported);
        supportedSport[_sportId] = _isSupported;
        emit SupportedSportsChanged(_sportId, _isSupported);
    }

    /// @notice sets resolved status which is supported or not
    /// @param _status status ID which needs to be supported or not
    /// @param _isSupported true/false (supported or not)
    function setSupportedResolvedStatuses(uint _status, bool _isSupported) external onlyOwner {
        require(supportResolveGameStatuses[_status] != _isSupported);
        supportResolveGameStatuses[_status] = _isSupported;
        emit SupportedResolvedStatusChanged(_status, _isSupported);
    }

    /// @notice sets cancel status which is supported or not
    /// @param _status ststus ID which needs to be supported or not
    /// @param _isSupported true/false (supported or not)
    function setSupportedCancelStatuses(uint _status, bool _isSupported) external onlyOwner {
        require(cancelGameStatuses[_status] != _isSupported);
        cancelGameStatuses[_status] = _isSupported;
        emit SupportedCancelStatusChanged(_status, _isSupported);
    }

    /// @notice sets ignoring children cancelation
    /// @param _sportId sport if
    /// @param _flag true/false
    function setIgnoreChildCancellationPerSportIfDraw(uint _sportId, bool _flag) external onlyOwner {
        ignoreChildCancellationPerSportIfDraw[_sportId] = _flag;
        emit IgnoreChildCancellationPerSportIfDraw(_sportId, _flag);
    }

    /// @notice sets if sport is two positional (Example: NBA)
    /// @param _sportId sport ID which is two positional
    /// @param _isTwoPosition true/false (two positional sport or not)
    function setTwoPositionSport(uint _sportId, bool _isTwoPosition) external onlyOwner {
        require(supportedSport[_sportId] && twoPositionSport[_sportId] != _isTwoPosition);
        twoPositionSport[_sportId] = _isTwoPosition;
        emit TwoPositionSportChanged(_sportId, _isTwoPosition);
    }

    /// @notice sets how many markets (main + children) are processed without queue
    /// @param _maxNumberOfMarketsToResolve max number of markets for automatic resolve w/o queue entering
    function setNewMaxNumberOfMarketsToResolveAndResolve(uint _maxNumberOfMarketsToResolve, uint _maxNumberOfMarketsToCreate)
        external
        onlyOwner
    {
        require(
            maxNumberOfMarketsToResolve != _maxNumberOfMarketsToResolve ||
                maxNumberOfMarketsToCreate != _maxNumberOfMarketsToCreate
        );
        maxNumberOfMarketsToResolve = _maxNumberOfMarketsToResolve;
        maxNumberOfMarketsToCreate = _maxNumberOfMarketsToCreate;
        emit NewMaxNumberOfMarketsToResolveAndCreate(_maxNumberOfMarketsToResolve, _maxNumberOfMarketsToCreate);
    }

    /// @notice sets wrapper, manager, queue  address
    /// @param _wrapperAddress wrapper address
    /// @param _queues queue address
    /// @param _sportsManager sport manager address
    function setSportContracts(
        address _wrapperAddress,
        GamesQueue _queues,
        address _sportsManager,
        address _verifier,
        address _oddsObtainer,
        address _playerProps
    ) external onlyOwner {
        sportsManager = ISportPositionalMarketManager(_sportsManager);
        queues = _queues;
        wrapperAddress = _wrapperAddress;
        verifier = ITherundownConsumerVerifier(_verifier);
        oddsObtainer = IGamesOddsObtainer(_oddsObtainer);
        playerProps = IGamesPlayerProps(_playerProps);

        emit NewSportContracts(_wrapperAddress, _queues, _sportsManager, _verifier, _oddsObtainer, _playerProps);
    }

    /// @notice adding/removing whitelist address depending on a flag
    /// @param _whitelistAddress address that needed to be whitelisted/ ore removed from WL
    /// @param _flag adding or removing from whitelist (true: add, false: remove)
    function addToWhitelist(address _whitelistAddress, bool _flag) external onlyOwner {
        require(_whitelistAddress != address(0) && whitelistedAddresses[_whitelistAddress] != _flag);
        whitelistedAddresses[_whitelistAddress] = _flag;
        emit AddedIntoWhitelist(_whitelistAddress, _flag);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyWrapper() {
        require(msg.sender == wrapperAddress, "ID9");
        _;
    }

    modifier canExecute() {
        require(msg.sender == address(oddsObtainer) || msg.sender == address(playerProps), "ID18");
        _;
    }

    modifier isAddressWhitelisted() {
        require(whitelistedAddresses[msg.sender], "ID10");
        _;
    }

    modifier canGameBeResolved(
        bytes32 _gameId,
        uint _outcome,
        uint8 _homeScore,
        uint8 _awayScore
    ) {
        require(!isGameResolvedOrCanceled(_gameId), "ID13");
        require(marketPerGameId[_gameId] != address(0), "ID14");
        require(
            verifier.isValidOutcomeForGame(twoPositionSport[sportsIdPerGame[_gameId]], _outcome) &&
                verifier.isValidOutcomeWithResult(_outcome, _homeScore, _awayScore),
            "ID15"
        );
        _;
    }
    /* ========== EVENTS ========== */

    event GameCreated(
        bytes32 _requestId,
        uint _sportId,
        bytes32 _id,
        GameCreate _game,
        uint _queueIndex,
        uint[] _normalizedOdds
    );
    event GameResolved(bytes32 _requestId, uint _sportId, bytes32 _id, GameResolve _game, uint _queueIndex);
    event CreateSportsMarket(address _marketAddress, bytes32 _id, GameCreate _game, uint[] _tags, uint[] _normalizedOdds);
    event ResolveSportsMarket(address _marketAddress, bytes32 _id, uint _outcome);
    event PauseSportsMarket(address _marketAddress, bool _pause);
    event CancelSportsMarket(address _marketAddress, bytes32 _id);
    event SupportedSportsChanged(uint _sportId, bool _isSupported);
    event SupportedResolvedStatusChanged(uint _status, bool _isSupported);
    event SupportedCancelStatusChanged(uint _status, bool _isSupported);
    event TwoPositionSportChanged(uint _sportId, bool _isTwoPosition);
    event NewSportContracts(
        address _wrapperAddress,
        GamesQueue _queues,
        address _sportsManager,
        address _verifier,
        address _oddsObtainer,
        address _playerProps
    );
    event AddedIntoWhitelist(address _whitelistAddress, bool _flag);
    event NewMaxNumberOfMarketsToResolveAndCreate(uint _maxNumberResolve, uint _maxNumberCreate);
    event GameTimeMovedAhead(address _market, bytes32 _gameId, uint _oldStartTime, uint _newStartTime);
    event IgnoreChildCancellationPerSportIfDraw(uint _sportId, bool _flag);
}

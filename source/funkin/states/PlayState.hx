package funkin.states;

import flixel.FlxCamera;
import flixel.FlxObject;
import flixel.FlxSubState;
import flixel.math.FlxMath;
import flixel.sound.FlxSound;
import flixel.util.FlxTimer;

import forever.core.scripting.*;
import forever.display.ForeverSprite;
import forever.display.RecycledSpriteGroup;

import funkin.components.ChartLoader;
import funkin.components.Timings;
import funkin.components.parsers.ForeverEvents as ChartEventOptions;
import funkin.objects.*;
import funkin.objects.StageBase;
import funkin.objects.play.Note;
import funkin.states.base.FNFState;
import funkin.states.editors.*;
import funkin.states.menus.*;
import funkin.ui.ComboSprite;

enum abstract GameplayMode(Int) to Int {
	var STORY = 0;
	var FREEPLAY = 1;
	var CHARTER = 2;
}

enum abstract MusicState(Int) to Int {
	var STOPPED = 0;
	var PLAYING = 1;
	var PAUSED = 2;
}

typedef PlaySong = {
	var display:String;
	var folder:String;
	var difficulty:String;
}

class PlayState extends FNFState {
	public static var current:PlayState;

	public var songMeta:PlaySong = {display: "Test", folder: "test", difficulty: "normal"};
	public var playMode:Int = FREEPLAY;
	public var songState:Int = STOPPED;

	public var bg:ForeverSprite;
	public var playField:PlayField;

	public var camLead:FlxObject;

	public var gameCamera:FlxCamera;
	public var hudCamera:FlxCamera;
	public var altCamera:FlxCamera;

	public var stage:StageBase;

	public var player:Character;
	public var enemy:Character;
	public var crowd:Character;

	public var inst:FlxSound;
	public var vocals:FlxSound;

	public var comboGroup:RecycledSpriteGroup<ComboSprite>;

	/**
	 * Constructs the Gameplay State
	 * @param songInfo 			Assigns a new song to the PlayState.
	**/
	public function new(songInfo:PlaySong):Void {
		super();
		this.songMeta = songInfo;
	}

	override function create():Void {
		super.create();

		current = this;

		if (FlxG.sound.music != null)
			FlxG.sound.music.stop();

		if (Conductor.active != true) // false or null
			Conductor.active = true;

		scriptPack = initAllScriptsAt([
			AssetHelper.getPath("data/scripts/global"),
			AssetHelper.getPath('songs/${songMeta.folder}/scripts'),
		]);
		setPackVar('game', this);
		callFunPack("create", []);

		// -- PREPARE AUDIO -- //
		vocals = new FlxSound();

		var instTrack = null;
		var vocalTrack = null;

		// -- FIXES FOR LINUX -- //

		var audioFolder:String = 'songs/${songMeta.folder}/audio';
		for (i in Tools.listFiles(AssetHelper.getPath(audioFolder))) {
			var fileName:String = i.toLowerCase().replace("." + haxe.io.Path.extension(i), "");
			if (fileName == "inst")
				instTrack = AssetHelper.getAsset('${audioFolder}/${i}', SOUND);
			if (fileName == "vocals" || fileName == "voices")
				vocalTrack = AssetHelper.getAsset('${audioFolder}/${i}', SOUND);
		}

		if (instTrack != null) {
			inst = new FlxSound().loadEmbedded(instTrack);
			FlxG.sound.music = inst;
			inst.onComplete = endPlay.bind();
			FlxG.sound.music.looped = false;
		}
		if (vocalTrack != null) {
			vocals.loadEmbedded(vocalTrack);
			FlxG.sound.list.add(vocals);
			vocals.looped = false;
		}
		Timings.reset();

		Conductor.time = -(60.0 / Conductor.bpm) * 16.0;
		FlxG.mouse.visible = false;

		// -- PREPARE CAMERAS -- //
		gameCamera = FlxG.camera;
		hudCamera = new FlxCamera();
		altCamera = new FlxCamera();

		hudCamera.bgColor = altCamera.bgColor = 0xFF000000;
		hudCamera.bgColor.alphaFloat = Tools.toFloatPercent(Settings.stageDim);
		altCamera.bgColor.alphaFloat = 0.0;

		FlxG.cameras.add(hudCamera, false);
		FlxG.cameras.add(altCamera, false);

		// -- PREPARE BACKGROUND -- //
		add(stage = new StageBase(Chart.current.gameInfo.stageBG));
		gameCamera.zoom = stage.cameraZoom;
		hudCamera.zoom = stage.hudZoom;

		// -- SETUP CAMERA -- //
		add(camLead = new FlxObject(0, 0, 1, 1));
		gameCamera.follow(camLead, LOCKON);

		// -- PREPARE CHARACTERS -- //
		add(player = new Character(stage.playerPosition.x, stage.playerPosition.y, Chart.current.gameInfo.chars[0], true));
		add(enemy = new Character(stage.enemyPosition.x, stage.enemyPosition.y, Chart.current.gameInfo.chars[1], false));
		add(crowd = new Character(stage.crowdPosition.x, stage.crowdPosition.y, Chart.current.gameInfo.chars[2], false));

		// -- PREPARE USER INTERFACE -- //
		add(comboGroup = new RecycledSpriteGroup<ComboSprite>());
		add(playField = new PlayField());
		for (hud in playField.getHUD())
			hud.alpha = 0;

		playField.camera = hudCamera;
		if (Settings.fixedJudgements)
			comboGroup.camera = hudCamera;

		// -- PREPARE CHART AND NOTEFIELDS -- //
		Conductor.bpm = Chart.current.songInfo.beatsPerMinute;

		for (lane in playField.strumLines) {
			lane.onNoteHit.add(hitBehavior);
			lane.onNoteMiss.add(missBehavior);
		}

		for (i in 0...4) // preload notesplashes
			playField.plrStrums.createSplash({time: 0.0, dir: 0, type: "default"}, true, true);

		#if DISCORD
		DiscordRPC.updatePresenceDetails('Playing: ${songMeta.display}', '');
		#end

		// cache combo and stuff
		var comboCache:ComboSprite = new ComboSprite();
		comboCache.loadSprite("sick-perfect", playField.skin);
		comboCache.alpha = 0.0000001;
		comboGroup.add(comboCache);
		new FlxTimer().start(0.3, function(tmr:FlxTimer):Void comboCache.kill());

		callFunPack("createPost", []);

		countdownRoutine();
		if (Chart.current != null && Chart.current.events[0] != null)
			processEvent(Chart.current.events[0].event);
	}

	override function update(elapsed:Float):Void {
		super.update(elapsed);

		var updateEvt:CancellableEvent = new CancellableEvent();
		callFunPack("update", [elapsed, updateEvt]);
		if (updateEvt.cancelled)
			return;

		if (Conductor.time >= 0 && songState != PAUSED) {
			startPlay();
		}

		FlxG.camera.followLerp = FlxMath.bound(elapsed * 2.4 * stage.cameraSpeed * (FlxG.updateFramerate / 60.0), 0.0, 1.0);

		while (eventIndex < Chart.current.events.length) {
			var curEvent = Chart.current.events[eventIndex];
			if ((curEvent.time - Conductor.time) > 0.0)
				break;

			processEvent(curEvent.event);
			eventIndex += 1;
		}

		if (Controls.RESET && Settings.resetButton) {
			// die.
		}

		#if FE_DEBUG
		if (FlxG.keys.justPressed.SEVEN)
			openChartEditor();
		#end
		if (Controls.PAUSE)
			openPauseMenu();

		#if sys
		if (FlxG.keys.justPressed.SEVEN)
			sys.io.File.saveContent('./${songMeta.folder}-${songMeta.difficulty}.json', ChartLoader.exportChart(Chart.current));
		#end
		callFunPack("postUpdate", [elapsed]);
	}

	override function draw():Void {
		callFunPack("preDraw", []);
		super.draw();
		callFunPack("draw", []);
	}

	override function destroy():Void {
		callFunPack("destroy", []);
		while (scriptPack.length != 0)
			scriptPack.pop().destroy();
		current = null;
		Timings.reset();
		super.destroy();
	}

	public function hitBehavior(note:Note):Void {
		if (note.wasHit)
			return;

		var hitEvent:CancellableEvent = new CancellableEvent();
		callFunPack("hitBehavior", [note, hitEvent]);
		if (hitEvent.cancelled)
			return;

		final isEnemy:Bool = (note.parent == playField.enmStrums);
		var character:Character = isEnemy ? enemy : player;
		// TODO: a better system -Crow
		if (character.animationContext != 3) { // 3 means "special"
			character.playAnim(character.singingSteps[note.data.dir], true);
			character.holdTmr = 0.0;
		}
		if (vocals != null && vocals.playing)
			vocals.volume = 1.0;

		if (!note.parent.cpuControl) {
			var millisecondTiming:Float = Math.abs((note.data.time - Conductor.time) * 1000.0);
			var judgement:Judgement = Timings.judgeNote(millisecondTiming);
			Timings.totalMs += millisecondTiming;

			var params = Tools.getEnumParams(judgement);

			missPunishIncrease = 0.0;

			Timings.score += params[1];
			Timings.health += 0.035;
			if (Timings.combo < 0)
				Timings.combo = 0;
			Timings.combo += 1;

			Timings.totalNotesHit += 1;
			Timings.accuracyWindow += Math.max(0, params[2]);
			Timings.increaseJudgeHits(params[0]);

			if (params[3] || note.splash)
				note.parent.createSplash(note.data);

			final chosenType:ComboPopType = FlxMath.roundDecimal(Timings.accuracy, 2) >= 100 ? PERFECT : NORMAL;
			displayJudgement(params[0], note.data.time < Conductor.time, chosenType);
			displayCombo(Timings.combo, chosenType);

			Timings.updateRank();
			playField.updateScore();
		}

		note.parent.invalidateNote(note);
		note.wasHit = true;

		callFunPack("postHitBehavior", []);
	}

	private var missPunishIncrease:Float = 0.0;

	public function missBehavior(dir:Int, note:Note = null):Void {
		var missEvent:CancellableEvent = new CancellableEvent();
		callFunPack("missBehavior", [dir, note, missEvent]);
		if (missEvent.cancelled)
			return;

		if (note != null)
			note.parent.invalidateNote(note);
		if (vocals != null && vocals.playing)
			vocals.volume = 0.0;

		if (Timings.combo > 0)
			Timings.combo = 0;
		else
			Timings.combo--;
		Timings.score -= 250;
		if (missPunishIncrease <= 0.01) missPunishIncrease = 1.0;
		Timings.health -= 0.035 * missPunishIncrease;
		missPunishIncrease += 0.075;
		Timings.misses += 1;

		if (missPopups) {
			displayJudgement("miss", true, MISS);
			displayCombo(Timings.combo, MISS);
		}

		Timings.updateRank();
		playField.updateScore();

		callFunPack("postMissBehavior", [dir]);
	}

	/** Enables the Golden Judgements & Combo Popups when having a perfect combo. **/
	public var perfectPopups:Bool = true;
	/** Enables the Red Miss Popups when missing notes. **/
	public var missPopups:Bool = true;
	/** Enables the timing sprites when hitting notes too early or late. **/
	public var timingPopups:Bool = true;

	private var lastJSpr:ComboSprite = null;

	public function displayJudgement(name:String, isLate:Bool = false, type:ComboPopType = NORMAL):Void {
		if (type == PERFECT && name == "sick" && perfectPopups)
			name = "sick-perfect";

		final placement:Float = FlxG.width * 0.55;
		final jSpr:ComboSprite = comboGroup.recycleLoop(ComboSprite).resetProps();
		var size:Float = PlayField.isPixel ? 6.0 : 0.7;

		jSpr.loadSprite('${name}0', playField.skin);
		jSpr.antialiasing = !PlayField.isPixel;
		jSpr.scale.set(size, size);
		jSpr.updateHitbox();

		if (!Settings.fixedJudgements) {
			jSpr.screenCenter(Y);
			jSpr.x = placement - 40;
			jSpr.y += 60;
		}
		else {
			// todo: better placements
			jSpr.screenCenter(XY);
		}

		jSpr.timeScale = Conductor.rate;

		jSpr.acceleration.y = 550;
		jSpr.velocity.y = -FlxG.random.int(140, 175);
		jSpr.velocity.x = -FlxG.random.int(0, 10);

		final crochet:Float = (60.0 / Conductor.bpm);

		// sick and miss don't have timings blehhhh
		if (timingPopups && (name != "sick-perfect" && name != "sick" && name != "miss")) {
			final timing:ComboSprite = comboGroup.recycleLoop(ComboSprite).resetProps();
			var size:Float = PlayField.isPixel ? 6.0 : 0.7;

			timing.loadSprite('${name}-${isLate ? "late" : "early"}0', playField.skin);
			timing.antialiasing = !PlayField.isPixel;
			timing.scale.set(size, size);
			timing.updateHitbox();

			// set positions and stuff
			timing.timeScale = jSpr.timeScale;
			timing.setPosition(jSpr.x + (isLate ? 50 : -15), jSpr.y);
			timing.acceleration.set(jSpr.acceleration.x, jSpr.acceleration.y);
			timing.velocity.set(jSpr.velocity.x, jSpr.velocity.y);

			timing.tween({alpha: 0}, 0.4, {
				onComplete: function(twn:FlxTween):Void {
					timing.kill();
					comboGroup.remove(timing, true);
				},
				startDelay: crochet + (crochet * 4.0) * 0.05
			});
		}

		jSpr.tween({alpha: 0}, 0.4, {
			onComplete: function(twn:FlxTween):Void {
				jSpr.kill();
				comboGroup.remove(jSpr, true);
			},
			startDelay: crochet + (crochet * 4.0) * 0.05
		});

		lastJSpr = jSpr;
	}

	public function displayCombo(combo:Int, type:ComboPopType = NORMAL):Void {
		final prefix:String = (type == PERFECT && perfectPopups) ? "gold" : "normal";
		final comboArr:Array<String> = Std.string(combo).split("");
		final xOff:Float = comboArr.length - 3;

		for (i in 0...comboArr.length) {
			var comboName:String = '${prefix}${comboArr[i]}0';
			if (comboArr[i] == "-" && type == MISS)
				comboName = '${prefix}minus';

			final comboX:Float = (lastJSpr.x + lastJSpr.width) + (43 * (i - xOff)) - 200;
			final cnSpr:ComboSprite = comboGroup.recycleLoop(ComboSprite).resetProps();
			final size:Float = PlayField.isPixel ? 6.0 : 0.5;
			cnSpr.loadSprite(comboName, playField.skin);
			cnSpr.antialiasing = !PlayField.isPixel;

			cnSpr.x = comboX;
			cnSpr.y = lastJSpr.y + 90;

			if (type == MISS)
				cnSpr.color = FlxColor.fromRGB(204, 66, 66);

			cnSpr.scale.set(size, size);
			cnSpr.updateHitbox();

			cnSpr.timeScale = Conductor.rate;
			cnSpr.acceleration.y = FlxG.random.int(200, 300);
			cnSpr.velocity.y = -FlxG.random.int(140, 160);
			cnSpr.velocity.x = FlxG.random.int(-5, 5);

			final crochet:Float = (60.0 / Conductor.bpm);

			cnSpr.tween({alpha: 0}, 0.5, {
				onComplete: function(twn:FlxTween):Void {
					cnSpr.kill();
					comboGroup.remove(cnSpr, true);
				},
				startDelay: (crochet * 4.0) * 0.08
			});
		}
	}

	override function onBeat(beat:Int):Void {
		callFunPack("onBeat", [beat]);
		playField.onBeat(beat);
		// let 'em do their thing!
		doDancersDance(beat);
	}

	override function onStep(step:Int):Void {
		var soundTime:Float = vocals.time / 1000.0;
		if (Math.abs(Conductor.time - soundTime) > 20.0)
			vocals.time = FlxG.sound.music.time;
		callFunPack("onStep", [step]);
	}

	override function onBar(bar:Int):Void {
		for (contextNames in ["onBar", "onSection", "onMeasure"])
			callFunPack(contextNames, [bar]);
	}

	function doDancersDance(beat:Int):Void {
		var chars:Array<Character> = [player, enemy, crowd];
		for (character in chars) {
			if (character == null)
				continue;
			// 0 = IDLE | 1 = SING | 2 = MISS
			if (character.animationContext == 0 && beat % character.danceInterval == 0)
				character.dance();
		}
	}

	override function openSubState(SubState:FlxSubState):Void {
		if (FlxG.sound.music != null && FlxG.sound.music.playing)
			FlxG.sound.music.pause();
		if (vocals != null && vocals.playing)
			vocals.pause();
		super.openSubState(SubState);
	}

	override function closeSubState():Void {
		playField.paused = false;
		if (FlxG.sound.music != null && FlxG.sound.music.playing)
			FlxG.sound.music.resume();
		if (vocals != null && vocals.playing)
			vocals.resume();
		songState = PLAYING;
		#if DISCORD
		DiscordRPC.updatePresenceDetails('${songMeta.display}', '${playField.scoreBar.text}');
		#end
		pauseTweens(false);
		super.closeSubState();
	}

	public function preloadEvent(which:ChartEventOptions):Void {
		switch (which) {
			case ChangeCharacter(who, toCharacter):
			/*
				var newChar:Character = new Character(0, 0);
				newChar.loadCharacter(toCharacter);
				newChar.alpha = 0.000001;
				characterGroup.add(newChar);
			 */
			case Scripted(name, script, args):
			// init hscript here.
			default:
				// do nothing
		}
	}

	var eventIndex:Int = 0;

	public function processEvent(which:ChartEventOptions):Void {
		switch (which) {
			case FocusCamera(who, noEasing):
				var character:Character = getCharacterFromID(who);
				var xPoint:Float = character.getMidpoint().x + character.cameraDisplace.x;
				var yPoint:Float = character.getMidpoint().y + character.cameraDisplace.y;

				if (camLead.x != xPoint)
					camLead.setPosition(xPoint, yPoint);

			case ChangeCharacter(who, toCharacter):
				getCharacterFromID(who).loadCharacter(toCharacter);
			case PlaySound(soundName, volume):
				FlxG.sound.play(AssetHelper.getAsset('audio/sfx/${soundName}'), volume);
			case Scripted(name, script, args):
			// init hscript here.
			default:
				// do nothing
		}
	}

	// -- HELPER FUNCTIONS -- //

	function openChartEditor():Void {
		#if DISCORD
		DiscordRPC.updatePresenceDetails('Charting: ${songMeta.display}');
		#end
		final charter:ChartEditor = new ChartEditor();
		charter.camera = altCamera;
		playField.paused = true;
		songState = PAUSED;
		openSubState(charter);
	}

	function openPauseMenu():Void {
		pauseTweens(true);
		#if DISCORD
		DiscordRPC.updatePresenceDetails('${songMeta.display} [PAUSED]', '${playField.scoreBar.text}');
		#end
		final pause:PauseMenu = new PauseMenu();
		pause.camera = altCamera;
		playField.paused = true;
		songState = PAUSED;
		openSubState(pause);
	}

	function pauseTweens(resume:Bool):Void {
		FlxTween.globalManager.forEach(function(t) t.active = !resume);
		FlxTimer.globalManager.forEach(function(t) t.active = !resume);
	}

	function startPlay():Void {
		if (FlxG.sound.music.playing && songState != PAUSED)
			return;

		var startPlayEvt:CancellableEvent = new CancellableEvent();
		callFunPack("startPlay", [startPlayEvt]);
		if (startPlayEvt.cancelled)
			return;

		if (FlxG.sound.music != null) {
			FlxG.sound.music.play();
			vocals.play();
		}

		songState = PLAYING;
	}

	function endPlay():Void {
		var endPlayEvt:CancellableEvent = new CancellableEvent();
		callFunPack("endPlay", [endPlayEvt]);
		if (endPlayEvt.cancelled)
			return;

		FlxG.sound.music.stop();
		vocals.stop();

		var cb:Void->Void = switch playMode {
			case STORY: function():Void FlxG.switchState(new MainMenu());
			case CHARTER: function():Void {
					Conductor.init();
					openChartEditor();
				}
			case _: function():Void FlxG.switchState(new FreeplayMenu());
		}
		cb();
	}

	var countdownPosition:Int = 0;

	public function countdownRoutine():Void {
		var countdownEvt:CancellableEvent = new CancellableEvent();
		callFunPack("countdownRoutine", [countdownPosition, songState, countdownEvt]);
		if (countdownEvt.cancelled)
			return;

		if (songState != PLAYING) {
			Conductor.time = -(60.0 / Conductor.bpm) * 4.0;
			for (hud in playField.getHUD())
				FlxTween.tween(hud, {alpha: 1.0}, (60.0 / Conductor.bpm) * 2.0, {ease: FlxEase.sineIn});
		}

		final sounds:Array<String> = ['intro3', 'intro2', 'intro1', 'introGo'];
		final crochet:Float = (60.0 / Conductor.bpm);

		var countdownTimer:FlxTimer = new FlxTimer().start(crochet, function(tmr:FlxTimer) {
			doDancersDance(tmr.loopsLeft);

			var sprCount = getCountdownSprite(countdownPosition);
			if (sprCount != null) {
				sprCount.screenCenter();
				sprCount.timeScale = Conductor.rate;
				sprCount.camera = hudCamera;
				if (PlayField.isPixel) {
					sprCount.antialiasing = false;
					sprCount.scale.set(6.0, 6.0);
					sprCount.updateHitbox();
				}
				add(sprCount);

				sprCount.stopTweens();
				sprCount.tween({alpha: 0, y: sprCount.y + 100}, crochet, {
					ease: FlxEase.sineOut,
					onComplete: function(t) {
						sprCount.destroy();
					}
				});
			}

			FlxG.sound.play(AssetHelper.getAsset('audio/countdown/${playField.skin}/${sounds[countdownPosition]}', SOUND), 0.8);
			countdownPosition++;
			callFunPack("countdownProgress", [countdownPosition, songState]);
		}, 4);
	}

	inline function getCharacterFromID(id:Int):Character {
		return switch (id) {
			default: enemy;
			case 1: player;
			case 2: crowd;
		}
	}

	function getCountdownSprite(tick:Int):ForeverSprite {
		final sprites:Array<String> = ["prepare", "ready", "set", "go"];
		if (sprites[tick] != null && Tools.fileExists(AssetHelper.getPath('images/ui/${playField.skin}/${sprites[tick]}', IMAGE)))
			return new ForeverSprite(0, 0, 'images/ui/${playField.skin}/${sprites[tick]}', {"scale.x": 0.9, "scale.y": 0.9});
		return null;
	}
}

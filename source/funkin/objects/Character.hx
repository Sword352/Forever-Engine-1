package funkin.objects;

import flixel.math.FlxPoint;
import forever.core.scripting.HScript;
import forever.display.ForeverSprite;
import forever.tools.CodenameTools;
import haxe.xml.Access;

enum abstract CharacterAnimContext(Int) to Int {
	var IDLE = 0;
	var SING = 1;
	var MISS = 2;

	/** Special Animations prevent the Character from dancing until their current animation is over. **/
	var SPECIAL = 3;
}

/**
 * Character Object used during gameplay.
**/
class Character extends ForeverSprite {
	/** Used to track the character's name **/
	public var name:String = "bf";

	/** Used to declare the character's health icon. **/
	public var icon:String = "bf";

	/** Small data structure for the game over screen. **/
	public var gameOverInfo:Dynamic = {
		character: "bf-dead",
		/** Plays during the game over screen. **/
		loopMusic: "gameOver",
		/** Plays after hitting the confirm key on the game over screen. **/
		confirmSound: "gameOverEnd",
		/** Plays when entering the game over screen**/
		startSfx: "fnf_loss_sfx",
		/** deathLifter the sfx, and slightly delays the music, Used in week7 **/
		deathLines: "tank/jeffGameover-{1...25}"
	};

	/** Dance Steps, used to track which animations to play when calling `dance()` on a character. **/
	public var dancingSteps:Array<String> = ["idle"];

	/**
	 * Sing Steps, used to know which animations to use when singing
	 * this is note based, so LEFT note would be the first animation of the array, and so on...
	**/
	public var singingSteps:Array<String> = ["singLEFT", "singDOWN", "singUP", "singRIGHT"];

	/**
	 * Character offset in-game, doesn't affect the main offsets of the animations
	 * and simply acts as a global offset.
	**/
	public var positionDisplace:FlxPoint = FlxPoint.get(0, 0);

	/** Character camera offset, acts lie `positionDisplace`, but for the camera. **/
	public var cameraDisplace:FlxPoint = FlxPoint.get(0, 0);

	/** The sing duration time, makes the character idle after reaching 0. **/
	public var singDuration:Float = 4.0;

	/** The beat interval a character takes to headbop. **/
	public var danceInterval:Int = 2;

	/** Which animation state the character is currently at. **/
	public var animationContext:Int = IDLE;

	public var characterScript:HScript = null;

	@:dox(hide) public var holdTmr:Float = 0.0;

	@:dox(hide) private var _curDanceStep:Int = 0;
	@:dox(hide) private var _isPlayer:Bool = false;

	public function new(?x:Float = 0, ?y:Float = 0, ?character:String = null, player:Bool = false):Void {
		super(x, y);
		this._isPlayer = player;
		if (character != null)
			loadCharacter(character);
	}

	override function destroy():Void {
		if (characterScript != null)
			characterScript.call("destroy", []);
		cameraDisplace?.put();
		positionDisplace?.put();
		super.destroy();
	}

	public function loadCharacter(character:String):Character {
		this.name = character;

		var implementation:EngineImpl = FOREVER;
		var file:Dynamic = null;

		if (Tools.fileExists(AssetHelper.getPath('data/characters/${name}.json'))) {
			file = AssetHelper.parseAsset('data/characters/${name}', JSON);
			var crowChar:Bool = Reflect.hasField(file, "singList");
			implementation = crowChar ? CROW : PSYCH;
		}

		switch (character) {
			default:
				try
					parseFromImpl(file, implementation)
				catch (e:haxe.Exception) {
					// trace('[Character:loadCharacter]: Failed to parse "${implementation.toString()}" type character of name "${name}"\n\nError: ${e.details()}');
				}
		}

		if (Tools.fileExists(AssetHelper.getAsset('data/characters/${name}', HSCRIPT))) {
			characterScript = new HScript(AssetHelper.getAsset('data/characters/${name}', HSCRIPT));
			characterScript.set('char', this);
			@:privateAccess characterScript.set('isPlayer', this._isPlayer);
			characterScript.call('generate', []);
			cast(FlxG.state, funkin.states.base.FNFState).appendToScriptPack(characterScript);
		}

		if (_isPlayer)
			flipX = !flipX;

		x += positionDisplace.x;
		y += positionDisplace.y;

		dance();

		return this;
	}

	override function update(elapsed:Float):Void {
		updateAnimation(elapsed);
		if (animation.curAnim != null) {
			if (animationContext == SING)
				holdTmr += elapsed;
			else if (_isPlayer)
				holdTmr = 0.0;
			final stepDt:Float = ((60.0 / Conductor.bpm) * 4.0);
			if (holdTmr >= ((stepDt * 1000.0) * Conductor.rate) * singDuration * 0.0001) {
				dance();
				holdTmr = 0.0;
			}
		}
	}

	public function dance(forced:Bool = false):Void {
		if (animationContext == SPECIAL)
			return;
		playAnim(dancingSteps[_curDanceStep], forced);
		if (animationContext != IDLE) // same here
			animationContext = IDLE;
		_curDanceStep += 1;
		if (_curDanceStep > dancingSteps.length - 1)
			_curDanceStep = 0;
	}

	override function playAnim(name:String, ?forced:Bool = false, ?reversed:Bool = false, ?frame:Int = 0):Void {
		if (characterScript != null)
			characterScript.call("playAnim", [name, forced, reversed, frame]);

		if (singingSteps.contains(name) && animationContext != SING) //  && animationContext != SING isnt needed
			animationContext = SING;

		super.playAnim(name, forced, reversed, frame);

		if (characterScript != null)
			characterScript.call("postPlayAnim", [name, forced, reversed, frame]);
	}

	@:noPrivateAccess
	private function parseFromImpl(file:Dynamic, impl:EngineImpl):Void {
		switch (impl) {
			case FOREVER:
				var data = AssetHelper.parseAsset('data/characters/${name}.yaml', YAML);
				if (data == null)
					return
						trace('[Character:parseFromImpl()]: Character ${name} could not be parsed due to a inexistent file, Please provide a file called "${name}.yaml" in the "data/characters directory.');

				// automatically searches for packer and sparrow
				frames = AssetHelper.getAsset('images/${data.spritesheet}', ATLAS);

				var animations:Array<Dynamic> = data.animations ?? [];
				if (animations.length > 0) {
					for (i in animations) {
						addAtlasAnim(i.name, i.prefix, i.fps ?? 24, i.loop ?? false, cast(i.indices ?? []));
						if (i.x != null)
							setOffset(i.x, i.y);
					}
				}
				else
					addAtlasAnim("idle", "BF idle dance", 24, false, []);

				flipX = data.flip?.x ?? false;
				flipY = data.flip?.y ?? false;
				icon = data.icon;

				dancingSteps = data.dancingSteps ?? dancingSteps;
				singingSteps = data.singingSteps ?? singingSteps;

				singDuration = data.singDuration ?? 4.0;
				danceInterval = data.danceInterval ?? 2;

				positionDisplace.set(data.positionDisplace?.x ?? 0.0, data.positionDisplace?.y ?? 0.0);
				cameraDisplace.set(data.cameraDisplace?.x ?? 0.0, data.cameraDisplace?.y ?? 0.0);

			case PSYCH:
				var charImage:String = file?.image ?? 'characters/${name}';
				frames = AssetHelper.getAsset('images/${charImage}', ATLAS);

				var psychAnimArray:Array<Dynamic> = file.animations;
				for (anim in psychAnimArray) {
					addAtlasAnim(anim.anim, anim.name, anim.fps, anim.anim.loop, anim.indices);
					setOffset(anim.anim, anim.offsets[0], anim.offsets[1]);
				}

				// shouldnt this be array<float>?
				var globalOffset:Array<Dynamic> = file.position ?? [0, 0];
				var globalCamOffset:Array<Dynamic> = file.camera_position ?? [0, 0];

				positionDisplace.set(Std.parseFloat(globalOffset[0]), Std.parseFloat(globalOffset[1]));
				cameraDisplace.set(Std.parseFloat(globalCamOffset[0]), Std.parseFloat(globalCamOffset[1]));

				icon = file.healthicon;
				flipX = file.flip_x ?? false;
				scale.set(file.scale ?? 1.0, file.scale ?? 1.0);
				updateHitbox();
				singDuration = file.sing_duration ?? 4;

				if (animation.exists("danceLeft") && animation.exists("danceRight")) {
					dancingSteps = ["danceLeft", "danceRight"];
					danceInterval = 1;
				}

			/*
				case CODENAME:
					// * written by: @Ne_Eo * //

					var plainXML = AssetHelper.getAsset('data/characters/${name}', XML);
					var charXML = Xml.parse(plainXML).firstElement();
					if (charXML == null) throw new haxe.Exception("Missing \"character\" node in XML.");
					var xml = new Access(charXML);

					// no flxanimate support sadly

					var charImage = name;

					//if (xml.x.exists("isPlayer")) playerOffsets = (xml.x.get("isPlayer") == "true");
					//if (xml.x.exists("isGF")) isGF = (xml.x.get("isGF") == "true");
					if (xml.x.exists("x")) positionDisplace.x = Std.parseFloat(xml.x.get("x"));
					if (xml.x.exists("y")) positionDisplace.y = Std.parseFloat(xml.x.get("y"));
					if (xml.x.exists("gameOverChar")) gameOverCharacter = xml.x.get("gameOverChar");
					if (xml.x.exists("camx")) cameraDisplace.x = Std.parseFloat(xml.x.get("camx"));
					if (xml.x.exists("camy")) cameraDisplace.y = Std.parseFloat(xml.x.get("camy"));
					if (xml.x.exists("holdTime")) singDuration = Std.parseFloat(xml.x.get("holdTime")) ?? 4;
					if (xml.x.exists("flipX")) flipX = (xml.x.get("flipX") == "true");
					//if (xml.x.exists("icon")) icon = xml.x.get("icon");
					//if (xml.x.exists("color")) iconColor = FlxColor.fromString(xml.x.get("color"));
					if (xml.x.exists("scale")) {
						var scale = CodenameTools.getDefault(Std.parseFloat(xml.x.get("scale")), 1);
						this.scale.set(scale, scale);
						updateHitbox();
					}
					if (xml.x.exists("antialiasing")) antialiasing = (xml.x.get("antialiasing") == "true");
					if (xml.x.exists("sprite")) charImage = xml.x.get("sprite");

					frames = AssetHelper.getAsset('images/characters/${charImage}', ATLAS);

					animation.destroyAnimations();
					animDatas.clear();
					for (anim in xml.nodes.anim)
					{
						CodenameTools.addXMLAnimation(this, anim);
					}
			 */

			case CROW:
				frames = AssetHelper.getAsset('images/characters/${name}/${name}', ATLAS);

				var crowAnimList:Array<Dynamic> = file.animationList;
				for (animData in crowAnimList) {
					addAtlasAnim(animData.name, animData.prefix, animData.fps, animData.looped, animData.indices);
					setOffset(animData.name, animData.offset.x, animData.offset.y);
				}

				flipX = file.flip?.x ?? false;
				flipY = file.flip?.y ?? false;

				icon = name;

				dancingSteps = file.idleList ?? dancingSteps;
				singingSteps = file.singList ?? singingSteps;

				scale.set(file.scale?.x ?? 1.0, file.scale?.y ?? 1.0);
				updateHitbox();

			default:
				trace('[Character:parseFromImpl()]: Missing character parsing for "${impl.toString()}" on character $name.');
		}
	}
}

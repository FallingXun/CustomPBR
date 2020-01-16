Shader "Custom/CustomPBR"
{
	Properties
	{
		// _Color和_MainTex控制漫反射项中的材质纹理和颜色
		_Color ("Color", Color) = (1,1,1,1)
		_MainTex ("Albedo", 2D) = "white" {}

		// _SpeColor和_SpecGlossMap的RGB控制材质的高光反射颜色，_Glossiness和_SpecGlossMap的A控制材质粗糙度
		_Glossiness ("Smoothness", Range(0.0, 1.0)) = 0.5
		_SpeColor ("Specular", Color) = (0.2,0.2,0.2)
		_SpecGlossMap ("Specular (RGB) Smoothness (A)", 2D) = "white" {}

		// _BumpMap为材质法线纹理，_BumpScale控制凹凸程度
		_BumpScale ("Bump Scale", Float) = 1.0
		_BumpMap ("Normal Map", 2D) = "bump" {}

		// _EmissionColor和_EmissionMap控制自发光颜色
		_EmissionColor ("Emission Color", Color) = (0,0,0)
		_EmissionMap ("Emission", 2D) = "white" {}
	}
	SubShader
	{
		Tags{"RenderType" = "Opaque"}
		LOD 300

		CGINCLUDE
			#include "UnityCG.cginc"
			// Disney BRDF模型的漫反射项计算
			inline half3 CustomDisneyDiffuseTerm(half NdotV, half NdotL, half LdotH, half roughness, half3 baseColor){
				// F-D90参数
				half fd90 = 0.5 * 2 * roughness * LdotH * LdotH;
				// 光照方向部分
				half lightScatter = (1 + (fd90 - 1) * pow((1 - NdotL), 5));
				// 视角方向部分
				half viewScatter = (1 + (fd90 - 1) * pow((1 - NdotV), 5));

				return baseColor * UNITY_INV_PI * lightScatter * viewScatter; 
			}

			// 高光反射项的可见性项计算 Smith结合GGX
			inline half CustomSmithJointGGXVisibilityTerm(half NdotL, half NdotV, half roughness){
				half a2 = roughness * roughness;
				half lambdaV = NdotL * (NdotV * (1 - a2) + a2);
				half lambdaL = NdotV * (NdotL * (1 - a2) + a2);

				return 0.5f / (lambdaV + lambdaL + 1e-5f);
			}

			// 高光反射项的法线分布项计算 GGX
			inline half CustomGGXTerm(half NdotH, half roughness){
				half a2 = roughness * roughness;
				half d = (NdotH * a2 - NdotH) * NdotH + 1.0f;

				return UNITY_INV_PI * a2 / (d * d + 1e-7f);
			}

			// 高光反射项的菲涅耳反射项计算 Schlick
			inline half3 CustomFresnelTerm(half3 c, half cosA){
				half t = pow(1 - cosA, 5);

				return c + (1 - c) * t;
			}

			// 对高光反射颜色speColor和掠射颜色grazingTerm进行插值，可以在掠射角得到更加真实的菲涅耳反射效果，同时还考虑了粗糙度的影响
			inline half3 CustomFresnelLerp(half3 c0, half3 c1, half cosA) {
				half t = pow(1 - cosA, 5);

				return lerp (c0, c1, t);
			}

		ENDCG

		Pass{
			// 计算一个逐像素的平行光以及所有逐顶点和SH光源
			Name "FORWARDBASE"

			Tags{ "LightMode" = "ForwardBase" }

			CGPROGRAM
			#pragma target 3.0
			#pragma multi_compile_fwdbase
			#pragma multi_compile_fog

			#include "UnityCG.cginc"
			#include "AutoLight.cginc"
			#include "HLSLSupport.cginc"
			#include "lighting.cginc"	//使用_LightColor0

			#pragma vertex vert
			#pragma fragment frag

			struct a2v{
				float4 vertex : POSITION;
				float3 normal : NORMAL;
				float4 tangent : TANGENT;
				float4 texcoord : TEXCOORD0;
			};

			struct v2f{
				float4 pos : SV_POSITION;
				float2 uv : TEXCOORD0;
				float4 TtoW0 : TEXCOORD1;
				float4 TtoW1 : TEXCOORD2;
				float4 TtoW2 : TEXCOORD3;
				SHADOW_COORDS(4)		// AutoLight.cginc定义
				UNITY_FOG_COORDS(5)		// UnityCG.cginc定义
			};

			fixed4 _Color;
			sampler2D _MainTex;
			float4 _MainTex_ST;
			fixed _Glossiness;
			fixed4 _SpeColor;
			sampler2D _SpecGlossMap;
			float _BumpScale;
			sampler2D _BumpMap;
			fixed4 _EmissionColor;
			sampler2D _EmissionMap;

			v2f vert(a2v v){
				v2f o;
				// 在HLSLSupport.cginc中定义，初始化输出变量为0
				UNITY_INITIALIZE_OUTPUT(v2f, o);

				o.pos = UnityObjectToClipPos(v.vertex);
				o.uv = TRANSFORM_TEX(v.texcoord, _MainTex);

				float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;

				fixed3 worldNormal = UnityObjectToWorldNormal(v.normal);
				fixed3 worldTangent = UnityObjectToWorldDir(v.tangent);
				fixed3 worldBinormal = cross(worldNormal, worldTangent) * v.tangent.w;	//乘以w分量确定方向

				o.TtoW0 = float4(worldTangent.x, worldBinormal.x,worldNormal.x,worldPos.x);
				o.TtoW1 = float4(worldTangent.y, worldBinormal.y,worldNormal.y,worldPos.y);
				o.TtoW2 = float4(worldTangent.z, worldBinormal.z,worldNormal.z,worldPos.z);

				TRANSFER_SHADOW(o);

				UNITY_TRANSFER_FOG(o, o.pos);

				return o;
			}

			half4 frag(v2f i) : SV_Target{

				half4 specGloss = tex2D(_SpecGlossMap, i.uv);
				specGloss.a *= _Glossiness;
				half3 specColor = specGloss.rgb * _SpeColor.rgb;
				// 粗糙度参数
				half roughness = 1 - specGloss.a;
				// 计算掠射角的反射颜色变量
				half oneMinusReflectivity  = 1 - max(max(specColor.r, specColor.g), specColor.b);

				half3 diffColor = _Color.rgb * tex2D(_MainTex, i.uv).rgb * oneMinusReflectivity;

				half3 normalTangent = UnpackNormal(tex2D(_BumpMap, i.uv));
				normalTangent.xy *= _BumpScale;
				normalTangent.z = sqrt(1.0 - saturate(dot(normalTangent.xy, normalTangent.xy)));

				half3 worldNormal = normalize(half3(dot(i.TtoW0.xyz, normalTangent), dot(i.TtoW1.xyz, normalTangent), dot(i.TtoW2.xyz, normalTangent)));
				
				float3 worldPos = float3(i.TtoW0.w, i.TtoW1.w, i.TtoW2.w);

				half3 lightDir = normalize(UnityWorldSpaceLightDir(worldPos));

				half3 viewDir = normalize(UnityWorldSpaceViewDir(worldPos));

				half3 reflDir = reflect(-viewDir, worldNormal);	//

				UNITY_LIGHT_ATTENUATION(atten, i, worldPos);

				// 计算各个公式中的点乘项
				half3 halfDir = normalize(lightDir + viewDir);
				half nv = saturate(dot(worldNormal, viewDir));
				half nl = saturate(dot(worldNormal, lightDir));
				half nh = saturate(dot(worldNormal, halfDir));
				half lv = saturate(dot(lightDir, viewDir));
				half lh = saturate(dot(lightDir, halfDir));

				// 漫反射项
				half3 diffuseTerm = CustomDisneyDiffuseTerm(nv, nl, lh, roughness, diffColor);

				// 高光反射项
				// 1.菲涅耳反射项 F(l,v) 活跃微面元的反射光占入射光的比率
				half3 F = CustomFresnelTerm(specColor, lh);
				// 2.法线分布项 D(h)  GGX  法线m=h的微面元的浓度（即能将入射光反射到观察方向的微面元占比）
				half D = CustomGGXTerm(nh, roughness * roughness);	// 粗糙度α = roughness ^ 2
				// 3.可见项V = 阴影-遮挡函数 G(l,v,h) / (nl * nv)  Smith+GGX  不被其他微面元遮挡的活跃微面元比例
				half V = CustomSmithJointGGXVisibilityTerm(nl, nv, roughness);
				half3 specularTerm =   F * D * V;

				// 自发光项
				half3 emissionTerm = tex2D(_EmissionMap, i.uv).rgb * _EmissionColor.rgb;

				// 精确光源下的渲染方程
				half3 col = emissionTerm + UNITY_PI * (diffuseTerm + specularTerm) * _LightColor0.rgb * nl * atten;

				// 基于图像的光照 IBL
				// 粗糙度材质
				half perceptualRoughness = roughness * (1.7 - 0.7 * roughness);
				// 多级渐远纹理级数 = 材质粗糙度 * 常数（整个粗糙度范围内多级渐远纹理的总级数）
				half mip = perceptualRoughness * 6;
				// unity_SpecCube0包含了该物体周围当前活跃的反射探针中包含的环境贴图
				half4 envMap = UNITY_SAMPLE_TEXCUBE_LOD(unity_SpecCube0, reflDir, mip);
				// 掠射颜色
				half grazingTerm = saturate((1 - roughness) + (1 - oneMinusReflectivity));
				// 修正IBL参数
				half surfaceReduction = 1.0 / (roughness * roughness + 1.0);
				half3 indirectSpecular = surfaceReduction * envMap.rgb * CustomFresnelLerp(specColor, grazingTerm, nv);

				col += indirectSpecular;

				// 雾效
				UNITY_APPLY_FOG(i.fogCoord, col.rgb);

				return half4(col, 1); 
			}

			ENDCG
		}
		Pass{
			// 计算其他影响该物体的逐像素光源，每个光源执行一次Pass
			Name "FORWARDADD"

			Tags{ "LightMode" = "ForwardAdd" }

			// 将上一次的光照结果在帧缓存中叠加
			Blend One One

			CGPROGRAM
			#pragma target 3.0
			#pragma multi_compile_fwdadd

			#include "UnityCG.cginc"
			#include "AutoLight.cginc"
			#include "HLSLSupport.cginc"
			#include "lighting.cginc"	//使用_LightColor0

			#pragma vertex vert
			#pragma fragment frag

			struct a2v{
				float4 vertex : POSITION;
				float3 normal : NORMAL;
				float4 tangent : TANGENT;
				float4 texcoord : TEXCOORD0;
			};

			struct v2f{
				float4 pos : SV_POSITION;
				float2 uv : TEXCOORD0;
				float4 TtoW0 : TEXCOORD1;
				float4 TtoW1 : TEXCOORD2;
				float4 TtoW2 : TEXCOORD3;
			};

			fixed4 _Color;
			sampler2D _MainTex;
			float4 _MainTex_ST;
			fixed _Glossiness;
			fixed4 _SpeColor;
			sampler2D _SpecGlossMap;
			float _BumpScale;
			sampler2D _BumpMap;
			fixed4 _EmissionColor;
			sampler2D _EmissionMap;

			v2f vert(a2v v){
				v2f o;
				// 在HLSLSupport.cginc中定义，初始化输出变量为0
				UNITY_INITIALIZE_OUTPUT(v2f, o);

				o.pos = UnityObjectToClipPos(v.vertex);
				o.uv = TRANSFORM_TEX(v.texcoord, _MainTex);

				float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;

				fixed3 worldNormal = UnityObjectToWorldNormal(v.normal);
				fixed3 worldTangent = UnityObjectToWorldDir(v.tangent);
				fixed3 worldBinormal = cross(worldNormal, worldTangent) * v.tangent.w;	//乘以w分量确定方向

				o.TtoW0 = float4(worldTangent.x, worldBinormal.x,worldNormal.x,worldPos.x);
				o.TtoW1 = float4(worldTangent.y, worldBinormal.y,worldNormal.y,worldPos.y);
				o.TtoW2 = float4(worldTangent.z, worldBinormal.z,worldNormal.z,worldPos.z);


				return o;
			}

			half4 frag(v2f i) : SV_Target{

				half4 specGloss = tex2D(_SpecGlossMap, i.uv);
				specGloss.a *= _Glossiness;
				half3 specColor = specGloss.rgb * _SpeColor.rgb;
				// 粗糙度参数
				half roughness = 1 - specGloss.a;
				// 计算掠射角的反射颜色变量
				half oneMinusReflectivity  = 1 - max(max(specColor.r, specColor.g), specColor.b);

				half3 diffColor = _Color.rgb * tex2D(_MainTex, i.uv).rgb * oneMinusReflectivity;

				half3 normalTangent = UnpackNormal(tex2D(_BumpMap, i.uv));
				normalTangent.xy *= _BumpScale;
				normalTangent.z = sqrt(1.0 - saturate(dot(normalTangent.xy, normalTangent.xy)));

				half3 worldNormal = normalize(half3(dot(i.TtoW0.xyz, normalTangent), dot(i.TtoW1.xyz, normalTangent), dot(i.TtoW2.xyz, normalTangent)));
				
				float3 worldPos = float3(i.TtoW0.w, i.TtoW1.w, i.TtoW2.w);

				half3 lightDir = normalize(UnityWorldSpaceLightDir(worldPos));

				half3 viewDir = normalize(UnityWorldSpaceViewDir(worldPos));

				half3 reflDir = reflect(-viewDir, worldNormal);	//

				UNITY_LIGHT_ATTENUATION(atten, i, worldPos);

				// 计算各个公式中的点乘项
				half3 halfDir = normalize(lightDir + viewDir);
				half nv = saturate(dot(worldNormal, viewDir));
				half nl = saturate(dot(worldNormal, lightDir));
				half nh = saturate(dot(worldNormal, halfDir));
				half lv = saturate(dot(lightDir, viewDir));
				half lh = saturate(dot(lightDir, halfDir));

				// 漫反射项
				half3 diffuseTerm = CustomDisneyDiffuseTerm(nv, nl, lh, roughness, diffColor);

				// 高光反射项
				// 1.菲涅耳反射项 F(l,v) 活跃微面元的反射光占入射光的比率
				half3 F = CustomFresnelTerm(specColor, lh);
				// 2.法线分布项 D(h)  GGX  法线m=h的微面元的浓度（即能将入射光反射到观察方向的微面元占比）
				half D = CustomGGXTerm(nh, roughness * roughness);	// 粗糙度α = roughness ^ 2
				// 3.可见项V = 阴影-遮挡函数 G(l,v,h) / (nl * nv)  Smith+GGX  不被其他微面元遮挡的活跃微面元比例
				half V = CustomSmithJointGGXVisibilityTerm(nl, nv, roughness);
				half3 specularTerm =   F * D * V;


				// 精确光源下的渲染方程
				half3 col = UNITY_PI * (diffuseTerm + specularTerm) * _LightColor0.rgb * nl * atten;

				return half4(col, 1); 
			}

			ENDCG
		}
	}
}

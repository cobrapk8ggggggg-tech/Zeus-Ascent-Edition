import importlib.util,pathlib,unittest
spec=importlib.util.spec_from_file_location('compare',pathlib.Path(__file__).with_name('compare.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class ParityGateTests(unittest.TestCase):
    def test_empty_or_simulator_results_cannot_prove_parity(self):
        result=module.compare({},{});self.assertFalse(result['equivalent']);self.assertIn('physical_devices_required',result['problems'])
    def test_character_error_counts_real_substitutions_and_unicode(self):
        self.assertEqual(module.cer('こんにちは','こんにちは'),(0,5));self.assertEqual(module.cer('ABC','ADC'),(1,3));self.assertEqual(module.cer('é','e\u0301'),(0,1))
if __name__=='__main__':unittest.main()
